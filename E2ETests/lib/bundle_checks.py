"""Opaque-box bundle, codesign, entitlements, security gate, asset, and launch checks."""

from __future__ import annotations

import json
import os
import plistlib
import re
import signal
import struct
import subprocess
import tempfile
import time
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from lib.models import TestOutcome

FORBIDDEN_API_PATTERN = re.compile(
    r"(URLSession|NWConnection|CGEventPost|AXIsProcessTrusted|print\(|os_log\()"
)

EXPECTED_ICONSET_SIZES: dict[str, tuple[int, int]] = {
    "icon_16x16.png": (16, 16),
    "icon_16x16@2x.png": (32, 32),
    "icon_32x32.png": (32, 32),
    "icon_32x32@2x.png": (64, 64),
    "icon_128x128.png": (128, 128),
    "icon_128x128@2x.png": (256, 256),
    "icon_256x256.png": (256, 256),
    "icon_256x256@2x.png": (512, 512),
    "icon_512x512.png": (512, 512),
    "icon_512x512@2x.png": (1024, 1024),
}

KASTOR_PAPER_RGB = (238, 234, 246)
KASTOR_INK_RGB = (27, 19, 43)


@dataclass(slots=True)
class PNGImage:
    width: int
    height: int
    bit_depth: int
    color_type: int
    interlace: int
    rgba: bytes

    def pixel(self, x: int, y: int) -> tuple[int, int, int, int]:
        if not (0 <= x < self.width and 0 <= y < self.height):
            raise IndexError(f"Pixel ({x}, {y}) out of bounds for {self.width}x{self.height}")
        idx = (y * self.width + x) * 4
        return (
            self.rgba[idx],
            self.rgba[idx + 1],
            self.rgba[idx + 2],
            self.rgba[idx + 3],
        )


def _elapsed_ms(start: float) -> float:
    return (time.perf_counter() - start) * 1000.0


def _missing_outcome(
    self_test: bool,
    summary: str,
    details: dict[str, Any] | None = None,
    start: float | None = None,
) -> TestOutcome:
    duration_ms = _elapsed_ms(start) if start is not None else 0.0
    return TestOutcome(
        status="PENDING_IMPL" if self_test else "FAIL",
        duration_ms=duration_ms,
        summary=summary,
        details=details,
    )


def _paeth_predictor(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _unfilter_scanlines(
    raw: bytes, width: int, height: int, bpp: int
) -> bytearray:
    stride = width * bpp
    expected_len = height * (stride + 1)
    if len(raw) < expected_len:
        raise ValueError(f"Truncated PNG IDAT stream: {len(raw)} < {expected_len}")

    out = bytearray(height * stride)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        ftype = raw[pos]
        pos += 1
        row = raw[pos : pos + stride]
        pos += stride
        recon = bytearray(stride)

        if ftype == 0:
            recon[:] = row
        elif ftype == 1:
            for i in range(stride):
                left = recon[i - bpp] if i >= bpp else 0
                recon[i] = (row[i] + left) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                recon[i] = (row[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                left = recon[i - bpp] if i >= bpp else 0
                recon[i] = (row[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                left = recon[i - bpp] if i >= bpp else 0
                up = prev[i]
                up_left = prev[i - bpp] if i >= bpp else 0
                recon[i] = (row[i] + _paeth_predictor(left, up, up_left)) & 0xFF
        else:
            raise ValueError(f"Unsupported PNG filter type: {ftype}")

        out[y * stride : (y + 1) * stride] = recon
        prev = recon

    return out


def _decode_png_bytes(data: bytes) -> PNGImage:
    if len(data) < 8 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Invalid PNG signature")

    offset = 8
    width = height = bit_depth = color_type = compression = filter_method = interlace = -1
    idat_chunks: list[bytes] = []
    saw_ihdr = False
    saw_iend = False

    while offset + 8 <= len(data):
        length, ctype = struct.unpack(">I4s", data[offset : offset + 8])
        offset += 8
        if offset + length + 4 > len(data):
            raise ValueError(f"Truncated PNG chunk {ctype!r}")
        chunk_data = data[offset : offset + length]
        offset += length + 4  # skip CRC

        if ctype == b"IHDR":
            if len(chunk_data) != 13:
                raise ValueError("Invalid IHDR chunk length")
            width, height, bit_depth, color_type, compression, filter_method, interlace = (
                struct.unpack(">IIBBBBB", chunk_data)
            )
            saw_ihdr = True
        elif ctype == b"IDAT":
            idat_chunks.append(chunk_data)
        elif ctype == b"IEND":
            saw_iend = True
            break

    if not saw_ihdr or not saw_iend:
        raise ValueError("Missing IHDR or IEND chunk")
    if compression != 0 or filter_method != 0:
        raise ValueError(f"Unsupported compression={compression} filter={filter_method}")
    if bit_depth != 8 or interlace != 0 or color_type not in (0, 2, 4, 6):
        raise ValueError(
            f"Unsupported PNG format: bit_depth={bit_depth}, color_type={color_type}, interlace={interlace}"
        )

    bpp_map = {0: 1, 2: 3, 4: 2, 6: 4}
    bpp = bpp_map[color_type]
    raw = zlib.decompress(b"".join(idat_chunks))
    pixels = _unfilter_scanlines(raw, width, height, bpp)

    if color_type == 6:
        rgba = bytes(pixels)
    elif color_type == 2:
        rgba_buf = bytearray(width * height * 4)
        for i in range(width * height):
            src = i * 3
            dst = i * 4
            rgba_buf[dst] = pixels[src]
            rgba_buf[dst + 1] = pixels[src + 1]
            rgba_buf[dst + 2] = pixels[src + 2]
            rgba_buf[dst + 3] = 255
        rgba = bytes(rgba_buf)
    elif color_type == 4:
        rgba_buf = bytearray(width * height * 4)
        for i in range(width * height):
            src = i * 2
            dst = i * 4
            g = pixels[src]
            rgba_buf[dst] = g
            rgba_buf[dst + 1] = g
            rgba_buf[dst + 2] = g
            rgba_buf[dst + 3] = pixels[src + 1]
        rgba = bytes(rgba_buf)
    else:  # color_type == 0
        rgba_buf = bytearray(width * height * 4)
        for i in range(width * height):
            dst = i * 4
            g = pixels[i]
            rgba_buf[dst] = g
            rgba_buf[dst + 1] = g
            rgba_buf[dst + 2] = g
            rgba_buf[dst + 3] = 255
        rgba = bytes(rgba_buf)

    return PNGImage(
        width=width,
        height=height,
        bit_depth=bit_depth,
        color_type=color_type,
        interlace=interlace,
        rgba=rgba,
    )


def decode_png(path: Path) -> PNGImage:
    """Decode an 8-bit non-interlaced PNG to RGBA; falls back to sips if needed."""
    raw_bytes = path.read_bytes()
    try:
        return _decode_png_bytes(raw_bytes)
    except ValueError:
        with tempfile.TemporaryDirectory(prefix="kastor_sips_") as tmp:
            norm_path = Path(tmp) / "normalized.png"
            proc = subprocess.run(
                ["/usr/bin/sips", "-s", "format", "png", str(path), "--out", str(norm_path)],
                capture_output=True,
                text=True,
                check=False,
            )
            if proc.returncode != 0 or not norm_path.exists():
                raise
            return _decode_png_bytes(norm_path.read_bytes())


def compare_png_rgba(png_a: Path, png_b: Path) -> dict[str, Any]:
    """Compare two PNG images channel-by-channel (RGBA)."""
    img_a = decode_png(png_a)
    img_b = decode_png(png_b)
    if (img_a.width, img_a.height) != (img_b.width, img_b.height):
        return {
            "dimensions_match": False,
            "size_a": [img_a.width, img_a.height],
            "size_b": [img_b.width, img_b.height],
            "mae": 255.0,
            "max_diff": 255,
            "exact": False,
        }

    total_diff = 0
    max_diff = 0
    n = len(img_a.rgba)
    for ba, bb in zip(img_a.rgba, img_b.rgba):
        d = abs(ba - bb)
        total_diff += d
        if d > max_diff:
            max_diff = d

    mae = total_diff / n if n else 0.0
    return {
        "dimensions_match": True,
        "size": [img_a.width, img_a.height],
        "mae": round(mae, 4),
        "max_diff": max_diff,
        "exact": max_diff == 0,
    }


def compare_png_alpha(png_a: Path, png_b: Path) -> dict[str, Any]:
    """Compare alpha channels of two PNG images."""
    img_a = decode_png(png_a)
    img_b = decode_png(png_b)
    if (img_a.width, img_a.height) != (img_b.width, img_b.height):
        return {
            "dimensions_match": False,
            "size_a": [img_a.width, img_a.height],
            "size_b": [img_b.width, img_b.height],
            "mae_alpha": 255.0,
            "max_alpha_diff": 255,
            "exact": False,
        }

    total_diff = 0
    max_diff = 0
    pixel_count = img_a.width * img_a.height
    for i in range(3, len(img_a.rgba), 4):
        d = abs(img_a.rgba[i] - img_b.rgba[i])
        total_diff += d
        if d > max_diff:
            max_diff = d

    mae = total_diff / pixel_count if pixel_count else 0.0
    return {
        "dimensions_match": True,
        "size": [img_a.width, img_a.height],
        "mae_alpha": round(mae, 4),
        "max_alpha_diff": max_diff,
        "exact": max_diff == 0,
    }


def check_app_exists(app_path: Path, self_test: bool = False) -> TestOutcome:
    start = time.perf_counter()
    if not app_path.exists() or not app_path.is_dir():
        return _missing_outcome(
            self_test,
            f"App bundle not found at {app_path}",
            {"app_path": str(app_path)},
            start,
        )
    plist_path = app_path / "Contents" / "Info.plist"
    macos_dir = app_path / "Contents" / "MacOS"
    if not plist_path.is_file() or not macos_dir.is_dir():
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary=f"Incomplete .app bundle structure at {app_path}",
            details={"plist_exists": plist_path.is_file(), "macos_dir_exists": macos_dir.is_dir()},
        )
    executables = [p.name for p in macos_dir.iterdir() if p.is_file()]
    if "Kastor" not in executables:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary=f"Expected executable 'Kastor' in {macos_dir}, found {executables}",
            details={"executables": executables},
        )
    return TestOutcome(
        status="PASS",
        duration_ms=_elapsed_ms(start),
        summary=f"App bundle present at {app_path}",
        details={"app_path": str(app_path), "executables": executables},
    )


def _read_info_plist(app_path: Path) -> dict[str, Any]:
    plist_path = app_path / "Contents" / "Info.plist"
    return plistlib.loads(plist_path.read_bytes())


def check_info_plist(app_path: Path, self_test: bool = False) -> TestOutcome:
    start = time.perf_counter()
    plist_path = app_path / "Contents" / "Info.plist"
    if not plist_path.is_file():
        return _missing_outcome(
            self_test,
            f"Info.plist not found at {plist_path}",
            {"plist_path": str(plist_path)},
            start,
        )
    try:
        info = _read_info_plist(app_path)
    except Exception as exc:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary=f"Failed to parse Info.plist: {exc}",
        )

    failures: list[str] = []
    if info.get("CFBundleName") != "Kastor":
        failures.append(f"CFBundleName={info.get('CFBundleName')!r} != 'Kastor'")
    if info.get("CFBundleDisplayName") != "Kastor":
        failures.append(f"CFBundleDisplayName={info.get('CFBundleDisplayName')!r} != 'Kastor'")
    if info.get("CFBundleIdentifier") != "com.kastor.clipboard":
        failures.append(f"CFBundleIdentifier={info.get('CFBundleIdentifier')!r} != 'com.kastor.clipboard'")
    if info.get("CFBundleExecutable") != "Kastor":
        failures.append(f"CFBundleExecutable={info.get('CFBundleExecutable')!r} != 'Kastor'")
    if info.get("CFBundleIconFile") not in ("Kastor", "Kastor.icns"):
        failures.append(f"CFBundleIconFile={info.get('CFBundleIconFile')!r} not in ('Kastor', 'Kastor.icns')")
    if info.get("LSUIElement") is not True:
        failures.append(f"LSUIElement={info.get('LSUIElement')!r} is not True")
    if info.get("LSMinimumSystemVersion") != "14.0":
        failures.append(f"LSMinimumSystemVersion={info.get('LSMinimumSystemVersion')!r} != '14.0'")
    if info.get("CFBundlePackageType") != "APPL":
        failures.append(f"CFBundlePackageType={info.get('CFBundlePackageType')!r} != 'APPL'")
    if info.get("NSHighResolutionCapable") is not True:
        failures.append(f"NSHighResolutionCapable={info.get('NSHighResolutionCapable')!r} is not True")

    if failures:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary="Info.plist assertions failed: " + "; ".join(failures),
            details={"failures": failures, "info_plist": info},
        )
    return TestOutcome(
        status="PASS",
        duration_ms=_elapsed_ms(start),
        summary="Info.plist verified for Kastor (com.kastor.clipboard, LSUIElement=true, macOS 14.0)",
        details={"bundle_id": info.get("CFBundleIdentifier"), "icon_file": info.get("CFBundleIconFile")},
    )


def check_codesign_and_runtime(
    app_path: Path, require_universal: bool = False, self_test: bool = False
) -> TestOutcome:
    start = time.perf_counter()
    if not app_path.exists():
        return _missing_outcome(
            self_test,
            f"App bundle not found at {app_path}",
            {"app_path": str(app_path)},
            start,
        )

    verify_proc = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if verify_proc.returncode != 0:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary="codesign --verify --deep --strict failed",
            details={"returncode": verify_proc.returncode, "stderr": verify_proc.stderr.strip()},
        )

    dv_proc = subprocess.run(
        ["/usr/bin/codesign", "-dvvv", str(app_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if dv_proc.returncode != 0:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary="codesign -dvvv failed",
            details={"returncode": dv_proc.returncode, "stderr": dv_proc.stderr.strip()},
        )

    meta = dv_proc.stderr
    failures: list[str] = []
    if not re.search(r"^Identifier=com\.kastor\.clipboard$", meta, re.MULTILINE):
        failures.append("Missing Identifier=com.kastor.clipboard")
    if not re.search(r"flags=0x[0-9a-fA-F]+\([^)]*\bruntime\b", meta):
        failures.append("Hardened Runtime flag (runtime) missing in CodeDirectory")
    if not re.search(r"^TeamIdentifier=", meta, re.MULTILINE):
        failures.append("Missing TeamIdentifier line in codesign metadata")

    exe_name = "Kastor"
    plist_path = app_path / "Contents" / "Info.plist"
    if plist_path.is_file():
        try:
            exe_name = str(_read_info_plist(app_path).get("CFBundleExecutable", "Kastor"))
        except Exception:
            pass
    exe_path = app_path / "Contents" / "MacOS" / exe_name
    archs: list[str] = []
    if exe_path.is_file():
        lipo_proc = subprocess.run(
            ["/usr/bin/lipo", "-archs", str(exe_path)],
            capture_output=True,
            text=True,
            check=False,
        )
        if lipo_proc.returncode == 0:
            archs = lipo_proc.stdout.strip().split()
            if "arm64" not in archs:
                failures.append(f"arm64 missing from lipo -archs: {archs}")
            if require_universal and not {"x86_64", "arm64"}.issubset(set(archs)):
                failures.append(f"Universal (x86_64 + arm64) required, got {archs}")
        else:
            failures.append(f"lipo -archs failed: {lipo_proc.stderr.strip()}")
    else:
        failures.append(f"Executable missing at {exe_path}")

    if failures:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary="Codesign / runtime checks failed: " + "; ".join(failures),
            details={"failures": failures, "archs": archs, "codesign_stderr": meta},
        )
    return TestOutcome(
        status="PASS",
        duration_ms=_elapsed_ms(start),
        summary=f"Valid codesign + Hardened Runtime (archs: {' '.join(archs)})",
        details={"archs": archs},
    )


def check_entitlements(app_path: Path, self_test: bool = False) -> TestOutcome:
    start = time.perf_counter()
    if not app_path.exists():
        return _missing_outcome(
            self_test,
            f"App bundle not found at {app_path}",
            {"app_path": str(app_path)},
            start,
        )

    proc = subprocess.run(
        ["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(app_path)],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary="codesign -d --entitlements failed",
            details={
                "returncode": proc.returncode,
                "stderr": proc.stderr.decode("utf-8", errors="replace"),
            },
        )

    try:
        ent = plistlib.loads(proc.stdout)
    except Exception as exc:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary=f"Failed to parse entitlements XML from stdout: {exc}",
            details={
                "stdout": proc.stdout.decode("utf-8", errors="replace"),
                "stderr": proc.stderr.decode("utf-8", errors="replace"),
            },
        )

    expected = {"com.apple.security.app-sandbox": True}
    if ent != expected:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary=f"Unexpected entitlements: {ent!r} != {expected!r}",
            details={"entitlements": ent, "expected": expected},
        )
    return TestOutcome(
        status="PASS",
        duration_ms=_elapsed_ms(start),
        summary="Single App Sandbox entitlement verified",
        details={"entitlements": ent},
    )


def check_security_gate(
    project_root: Path, app_path: Path, self_test: bool = False
) -> TestOutcome:
    start = time.perf_counter()
    script_path = project_root / "scripts" / "security-gate.sh"
    if not script_path.is_file():
        return _missing_outcome(
            self_test,
            f"scripts/security-gate.sh not found at {script_path}",
            {"script_path": str(script_path)},
            start,
        )

    script_text = script_path.read_text(encoding="utf-8", errors="replace")
    script_issues: list[str] = []
    if "Kastor" not in script_text:
        script_issues.append("security-gate.sh does not reference Kastor")
    if re.search(r"impasto", script_text, re.IGNORECASE):
        script_issues.append("security-gate.sh still contains stale Impasto reference")
    if script_issues:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary="; ".join(script_issues),
            details={"script_path": str(script_path), "issues": script_issues},
        )

    if not app_path.exists():
        return _missing_outcome(
            self_test,
            f"security-gate.sh updated for Kastor, awaiting {app_path}",
            {"app_path": str(app_path)},
            start,
        )

    proc = subprocess.run(
        ["/bin/bash", str(script_path), str(app_path)],
        cwd=str(project_root),
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary=f"scripts/security-gate.sh exited {proc.returncode}",
            details={
                "returncode": proc.returncode,
                "stdout": proc.stdout.strip(),
                "stderr": proc.stderr.strip(),
            },
        )
    return TestOutcome(
        status="PASS",
        duration_ms=_elapsed_ms(start),
        summary="scripts/security-gate.sh passed with exit code 0",
        details={"stdout": proc.stdout.strip()},
    )


def check_forbidden_apis(project_root: Path, self_test: bool = False) -> TestOutcome:
    start = time.perf_counter()
    kastor_dir = project_root / "Kastor"
    if not kastor_dir.is_dir():
        return _missing_outcome(
            self_test,
            f"Kastor source directory not found at {kastor_dir}",
            {"kastor_dir": str(kastor_dir)},
            start,
        )

    swift_files = sorted(kastor_dir.rglob("*.swift"))
    if not swift_files:
        return _missing_outcome(
            self_test,
            f"No Swift files found under {kastor_dir}",
            {"kastor_dir": str(kastor_dir)},
            start,
        )

    hits: list[dict[str, Any]] = []
    for path in swift_files:
        for lineno, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            match = FORBIDDEN_API_PATTERN.search(line)
            if match:
                hits.append(
                    {
                        "file": str(path.relative_to(project_root)),
                        "line": lineno,
                        "token": match.group(1),
                        "text": line.strip(),
                    }
                )

    if hits:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary=f"Found {len(hits)} forbidden API occurrence(s) in Kastor/**/*.swift",
            details={"hits": hits},
        )
    return TestOutcome(
        status="PASS",
        duration_ms=_elapsed_ms(start),
        summary=f"Zero forbidden APIs across {len(swift_files)} Kastor Swift file(s)",
        details={"scanned_files": len(swift_files)},
    )


def check_package_resolved(project_root: Path, self_test: bool = False) -> TestOutcome:
    start = time.perf_counter()
    lock_path = (
        project_root
        / "Kastor.xcodeproj"
        / "project.xcworkspace"
        / "xcshareddata"
        / "swiftpm"
        / "Package.resolved"
    )
    if not lock_path.is_file():
        return _missing_outcome(
            self_test,
            f"Package.resolved not found at {lock_path}",
            {"lock_path": str(lock_path)},
            start,
        )

    try:
        data = json.loads(lock_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary=f"Invalid Package.resolved JSON: {exc}",
        )

    failures: list[str] = []
    if data.get("version") != 3:
        failures.append(f"Package.resolved version={data.get('version')!r} != 3")
    pins = data.get("pins", [])
    if not isinstance(pins, list) or len(pins) != 1:
        failures.append(f"Expected exactly 1 pin in Package.resolved, got {len(pins) if isinstance(pins, list) else type(pins).__name__}")
    else:
        pin = pins[0]
        if pin.get("identity") != "keyboardshortcuts":
            failures.append(f"Pin identity={pin.get('identity')!r} != 'keyboardshortcuts'")
        ver = (pin.get("state") or {}).get("version")
        if ver != "2.4.0":
            failures.append(f"KeyboardShortcuts pinned version={ver!r} != '2.4.0'")

    checkout_dir = project_root / "SourcePackages" / "checkouts" / "KeyboardShortcuts"
    if not checkout_dir.is_dir():
        failures.append(f"Offline checkout missing at {checkout_dir}")

    if failures:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary="; ".join(failures),
            details={"failures": failures, "lock_path": str(lock_path)},
        )
    return TestOutcome(
        status="PASS",
        duration_ms=_elapsed_ms(start),
        summary="Package.resolved v3 pins single dependency keyboardshortcuts@2.4.0 with offline checkout",
        details={"lock_path": str(lock_path)},
    )


def check_project_yml(project_root: Path, self_test: bool = False) -> TestOutcome:
    start = time.perf_counter()
    yml_path = project_root / "project.yml"
    if not yml_path.is_file():
        return _missing_outcome(
            self_test,
            f"project.yml not found at {yml_path}",
            {"yml_path": str(yml_path)},
            start,
        )

    text = yml_path.read_text(encoding="utf-8", errors="replace")
    failures: list[str] = []

    required_patterns = [
        (r"^name:\s*Kastor\b", "name: Kastor"),
        (r"^\s*exactVersion:\s*2\.4\.0\b", "exactVersion: 2.4.0"),
        (r"PRODUCT_BUNDLE_IDENTIFIER:\s*com\.kastor\.clipboard\b", "PRODUCT_BUNDLE_IDENTIFIER: com.kastor.clipboard"),
        (r"PRODUCT_BUNDLE_IDENTIFIER:\s*com\.kastor\.clipboard\.tests\b", "PRODUCT_BUNDLE_IDENTIFIER: com.kastor.clipboard.tests"),
        (r"SWIFT_TREAT_WARNINGS_AS_ERRORS:\s*YES\b", "SWIFT_TREAT_WARNINGS_AS_ERRORS: YES"),
        (r"ENABLE_HARDENED_RUNTIME:\s*YES\b", "ENABLE_HARDENED_RUNTIME: YES"),
        (r"ENABLE_APP_SANDBOX:\s*YES\b", "ENABLE_APP_SANDBOX: YES"),
        (r"CODE_SIGN_INJECT_BASE_ENTITLEMENTS:\s*NO\b", "CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO"),
    ]
    for pat, label in required_patterns:
        if not re.search(pat, text, re.MULTILINE):
            failures.append(f"Missing {label}")

    if re.search(r"impasto", text, re.IGNORECASE):
        failures.append("Stale Impasto reference found in project.yml")

    if failures:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary="project.yml checks failed: " + "; ".join(failures),
            details={"failures": failures},
        )
    return TestOutcome(
        status="PASS",
        duration_ms=_elapsed_ms(start),
        summary="project.yml verified (Kastor, 2.4.0 pin, warnings-as-errors, sandbox, hardened runtime)",
    )


def _resolve_icns_path(app_or_icns_path: Path) -> Path | None:
    if app_or_icns_path.suffix == ".icns":
        return app_or_icns_path if app_or_icns_path.is_file() else None
    if app_or_icns_path.suffix == ".app" and app_or_icns_path.is_dir():
        plist_path = app_or_icns_path / "Contents" / "Info.plist"
        icon_name = "Kastor.icns"
        if plist_path.is_file():
            try:
                info = plistlib.loads(plist_path.read_bytes())
                raw_name = str(info.get("CFBundleIconFile", "Kastor.icns"))
                icon_name = raw_name if raw_name.endswith(".icns") else f"{raw_name}.icns"
            except Exception:
                pass
        candidate = app_or_icns_path / "Contents" / "Resources" / icon_name
        if candidate.is_file():
            return candidate
        fallback = app_or_icns_path / "Contents" / "Resources" / "Kastor.icns"
        return fallback if fallback.is_file() else None
    return app_or_icns_path if app_or_icns_path.is_file() else None


def check_icns_against_reference(
    app_or_icns_path: Path, reference_assets_dir: Path, self_test: bool = False
) -> TestOutcome:
    start = time.perf_counter()
    icns_path = _resolve_icns_path(app_or_icns_path)
    if icns_path is None:
        return _missing_outcome(
            self_test,
            f"Kastor.icns not found at {app_or_icns_path}",
            {"target": str(app_or_icns_path)},
            start,
        )

    dock_ref = reference_assets_dir / "kastor-dock-1024.png"
    icon_ref = reference_assets_dir / "kastor-icon-1024.png"
    if not dock_ref.is_file() or not icon_ref.is_file():
        return TestOutcome(
            status="ERROR",
            duration_ms=_elapsed_ms(start),
            summary=f"Reference icon assets missing in {reference_assets_dir}",
            details={"dock_ref": dock_ref.is_file(), "icon_ref": icon_ref.is_file()},
        )

    icns_bytes = icns_path.read_bytes()
    if len(icns_bytes) < 8 or icns_bytes[:4] != b"icns":
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary=f"Invalid .icns header in {icns_path}",
        )
    declared_len = struct.unpack(">I", icns_bytes[4:8])[0]
    if declared_len != len(icns_bytes):
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary=f".icns length mismatch: header={declared_len} actual={len(icns_bytes)}",
        )

    with tempfile.TemporaryDirectory(prefix="kastor_icns_") as tmp:
        iconset_dir = Path(tmp) / "Kastor.iconset"
        proc = subprocess.run(
            ["/usr/bin/iconutil", "--convert", "iconset", str(icns_path), "-o", str(iconset_dir)],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0 or not iconset_dir.is_dir():
            return TestOutcome(
                status="FAIL",
                duration_ms=_elapsed_ms(start),
                summary=f"iconutil extraction failed for {icns_path}",
                details={"returncode": proc.returncode, "stderr": proc.stderr.strip()},
            )

        failures: list[str] = []
        extracted_sizes: dict[str, list[int]] = {}
        for filename, expected_size in EXPECTED_ICONSET_SIZES.items():
            png_path = iconset_dir / filename
            if not png_path.is_file():
                failures.append(f"Missing iconset file {filename}")
                continue
            img = decode_png(png_path)
            extracted_sizes[filename] = [img.width, img.height]
            if (img.width, img.height) != expected_size:
                failures.append(f"{filename} size {(img.width, img.height)} != {expected_size}")

        icon_1024_path = iconset_dir / "icon_512x512@2x.png"
        dock_cmp: dict[str, Any] = {}
        icon_ref_cmp: dict[str, Any] = {}
        if icon_1024_path.is_file():
            img_1024 = decode_png(icon_1024_path)
            for cx, cy in ((0, 0), (1023, 0), (0, 1023), (1023, 1023)):
                if img_1024.pixel(cx, cy)[3] != 0:
                    failures.append(f"icon_512x512@2x.png corner ({cx},{cy}) alpha != 0")
            center_px = img_1024.pixel(512, 512)
            if any(abs(center_px[i] - KASTOR_PAPER_RGB[i]) > 3 for i in range(3)) or center_px[3] != 255:
                failures.append(f"icon_512x512@2x.png center pixel {center_px} != #EEEAF6")

            dock_cmp = compare_png_rgba(icon_1024_path, dock_ref)
            if not dock_cmp.get("dimensions_match") or dock_cmp.get("mae", 255.0) > 3.0:
                failures.append(f"icon_512x512@2x.png MAE vs kastor-dock-1024.png = {dock_cmp.get('mae')} (> 3.0)")

            # Verify full-bleed reference kastor-icon-1024.png is valid & opaque #EEEAF6 corners
            ref_master = decode_png(icon_ref)
            if (ref_master.width, ref_master.height) != (1024, 1024):
                failures.append(f"kastor-icon-1024.png size {(ref_master.width, ref_master.height)} != (1024, 1024)")
            else:
                ref_corner = ref_master.pixel(0, 0)
                if ref_corner[3] != 255 or any(abs(ref_corner[i] - KASTOR_PAPER_RGB[i]) > 3 for i in range(3)):
                    failures.append(f"kastor-icon-1024.png corner {ref_corner} != opaque #EEEAF6")
            icon_ref_cmp = compare_png_rgba(icon_1024_path, icon_ref)
            if icon_ref_cmp.get("mae", 0.0) <= 10.0:
                failures.append("icon_512x512@2x.png appears full-bleed instead of squircle dock icon")

        if failures:
            return TestOutcome(
                status="FAIL",
                duration_ms=_elapsed_ms(start),
                summary="Kastor.icns verification failed: " + "; ".join(failures),
                details={
                    "icns_path": str(icns_path),
                    "failures": failures,
                    "dock_comparison": dock_cmp,
                    "icon_ref_comparison": icon_ref_cmp,
                },
            )

        return TestOutcome(
            status="PASS",
            duration_ms=_elapsed_ms(start),
            summary=f"Kastor.icns verified (10 iconset PNGs, dock MAE={dock_cmp.get('mae')})",
            details={
                "icns_path": str(icns_path),
                "extracted_count": len(extracted_sizes),
                "dock_comparison": dock_cmp,
            },
        )


def check_tray_png_references(reference_assets_dir: Path) -> TestOutcome:
    start = time.perf_counter()
    targets = {
        "TrayOption-D-18.png": (18, 18),
        "TrayOption-D-36.png": (36, 36),
    }
    metrics: dict[str, Any] = {}
    failures: list[str] = []

    for name, expected_size in targets.items():
        path = reference_assets_dir / name
        if not path.is_file():
            failures.append(f"Missing reference asset {path}")
            continue
        img = decode_png(path)
        if (img.width, img.height) != expected_size:
            failures.append(f"{name} size {(img.width, img.height)} != {expected_size}")
        max_rgb = 0
        nonzero_alpha = 0
        for i in range(0, len(img.rgba), 4):
            max_rgb = max(max_rgb, img.rgba[i], img.rgba[i + 1], img.rgba[i + 2])
            if img.rgba[i + 3] > 0:
                nonzero_alpha += 1
        if max_rgb != 0:
            failures.append(f"{name} is not black template mask (max_rgb={max_rgb})")
        if nonzero_alpha == 0:
            failures.append(f"{name} has zero alpha coverage")
        if img.pixel(0, 0)[3] != 0:
            failures.append(f"{name} corner (0,0) has non-zero alpha")
        metrics[name] = {
            "size": [img.width, img.height],
            "max_rgb": max_rgb,
            "nonzero_alpha_pixels": nonzero_alpha,
            "total_pixels": img.width * img.height,
        }

    if failures:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary="; ".join(failures),
            details={"failures": failures, "metrics": metrics},
        )
    return TestOutcome(
        status="PASS",
        duration_ms=_elapsed_ms(start),
        summary="TrayOption-D-18.png (18x18) & TrayOption-D-36.png (36x36) alpha masks verified",
        details=metrics,
    )


def check_headless_launch_and_quit(
    app_path: Path, self_test: bool = False
) -> TestOutcome:
    start = time.perf_counter()
    if not app_path.exists():
        return _missing_outcome(
            self_test,
            f"App bundle not found at {app_path}",
            {"app_path": str(app_path)},
            start,
        )

    plist_path = app_path / "Contents" / "Info.plist"
    if not plist_path.is_file():
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary=f"Info.plist missing at {plist_path}",
        )

    try:
        exe_name = str(_read_info_plist(app_path).get("CFBundleExecutable", "Kastor"))
    except Exception as exc:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary=f"Failed to read CFBundleExecutable: {exc}",
        )

    exe_path = app_path / "Contents" / "MacOS" / exe_name
    if not exe_path.is_file():
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary=f"Executable not found at {exe_path}",
        )

    diag_dir = Path.home() / "Library" / "Logs" / "DiagnosticReports"
    before_reports = (
        {p.name for p in diag_dir.iterdir()} if diag_dir.is_dir() else set()
    )

    with tempfile.TemporaryDirectory(prefix="kastor_launch_home_") as tmp_home:
        env = os.environ.copy()
        env["HOME"] = tmp_home
        proc = subprocess.Popen(
            [str(exe_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
        try:
            time.sleep(1.5)
            poll_result = proc.poll()
            if poll_result is not None:
                stdout_b, stderr_b = proc.communicate(timeout=2)
                return TestOutcome(
                    status="FAIL",
                    duration_ms=_elapsed_ms(start),
                    summary=f"App exited prematurely during launch (rc={poll_result})",
                    details={
                        "returncode": poll_result,
                        "stdout": stdout_b.decode("utf-8", errors="replace"),
                        "stderr": stderr_b.decode("utf-8", errors="replace"),
                    },
                )

            proc.terminate()
            try:
                stdout_b, stderr_b = proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=3)
                return TestOutcome(
                    status="FAIL",
                    duration_ms=_elapsed_ms(start),
                    summary="App did not terminate within 5s after SIGTERM",
                )
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=3)

    after_reports = (
        {p.name for p in diag_dir.iterdir()} if diag_dir.is_dir() else set()
    )
    new_reports = sorted(after_reports - before_reports)
    kastor_crashes = [r for r in new_reports if "kastor" in r.lower() or r.endswith((".ips", ".crash"))]

    stderr_str = stderr_b.decode("utf-8", errors="replace")
    failures: list[str] = []
    if proc.returncode not in (0, -signal.SIGTERM):
        failures.append(f"Unexpected exit code {proc.returncode}")
    if stderr_str.strip():
        failures.append(f"Non-empty stderr: {stderr_str.strip()!r}")
    if kastor_crashes:
        failures.append(f"New DiagnosticReports files detected: {kastor_crashes}")

    if failures:
        return TestOutcome(
            status="FAIL",
            duration_ms=_elapsed_ms(start),
            summary="Headless launch/quit failed: " + "; ".join(failures),
            details={
                "returncode": proc.returncode,
                "stderr": stderr_str,
                "new_reports": kastor_crashes,
            },
        )
    return TestOutcome(
        status="PASS",
        duration_ms=_elapsed_ms(start),
        summary=f"Headless launch stayed alive 1.5s and quit cleanly on SIGTERM (rc={proc.returncode})",
        details={"returncode": proc.returncode, "exe_path": str(exe_path)},
    )
