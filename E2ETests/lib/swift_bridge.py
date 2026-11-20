"""Swift driver compilation and execution bridge using xcrun swiftc in temp cache."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from lib.models import DEFAULT_REFERENCE_ASSETS_DIR, TestOutcome, TestStatus

AT_MAIN_PATTERN = re.compile(r"^\s*@main\b", re.MULTILINE)

FRAMEWORKS: tuple[str, ...] = (
    "AppKit",
    "ApplicationServices",
    "Carbon",
    "CoreGraphics",
    "CryptoKit",
    "ImageIO",
    "Security",
    "ServiceManagement",
    "SwiftUI",
    "UniformTypeIdentifiers",
)

BUNDLE_SHIM_SOURCE = """import Foundation

extension Foundation.Bundle {
    static let module: Bundle = .main
}
"""

EMPTY_CASES_STUB = """import Foundation

enum Tier1Cases { static var allCases: [SwiftDriverCase] { [] } }
enum Tier2Cases { static var allCases: [SwiftDriverCase] { [] } }
enum Tier3Cases { static var allCases: [SwiftDriverCase] { [] } }
enum Tier4Cases { static var allCases: [SwiftDriverCase] { [] } }
"""


@dataclass(slots=True)
class CompileResult:
    ok: bool
    binary_path: Path | None
    status: TestStatus
    message: str
    cached: bool = False
    stderr: str = ""


class SwiftBridge:
    """Compiles and runs the E2ETests/swift_driver harness cleanly via xcrun swiftc."""

    def __init__(
        self,
        project_root: Path,
        reference_assets_dir: Path = DEFAULT_REFERENCE_ASSETS_DIR,
        cache_root: Path | None = None,
    ) -> None:
        self.project_root = project_root
        self.reference_assets_dir = reference_assets_dir
        self.driver_dir = project_root / "E2ETests" / "swift_driver"
        self.cache_root = cache_root or (
            Path(tempfile.gettempdir()) / "kastor_e2e_swift_cache"
        )
        self.cache_root.mkdir(parents=True, exist_ok=True)
        self.arch = platform.machine() or "arm64"
        self.target = f"{self.arch}-apple-macosx14.0"

    def _discover_driver_sources(self) -> list[Path]:
        if not self.driver_dir.is_dir():
            return []
        return sorted(self.driver_dir.rglob("*.swift"))

    def _discover_kastor_sources(self) -> list[Path]:
        kastor_dir = self.project_root / "Kastor"
        if not kastor_dir.is_dir():
            return []
        result: list[Path] = []
        for path in sorted(kastor_dir.rglob("*.swift")):
            if path.name in ("KastorApp.swift", "ImpastoApp.swift"):
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            if AT_MAIN_PATTERN.search(text):
                continue
            result.append(path)
        return result

    def _discover_keyboard_shortcuts_sources(self) -> list[Path]:
        ks_dir = (
            self.project_root
            / "SourcePackages"
            / "checkouts"
            / "KeyboardShortcuts"
            / "Sources"
            / "KeyboardShortcuts"
        )
        if not ks_dir.is_dir():
            return []
        return sorted(ks_dir.glob("*.swift"))

    @staticmethod
    def _hash_files(paths: list[Path], extra: str = "") -> str:
        h = hashlib.sha256()
        h.update(extra.encode("utf-8"))
        for p in paths:
            stat = p.stat()
            h.update(str(p).encode("utf-8"))
            h.update(f":{stat.st_mtime_ns}:{stat.st_size}\n".encode("utf-8"))
            h.update(p.read_bytes())
        return h.hexdigest()[:20]

    def _compile_keyboard_shortcuts(self, self_test: bool, force: bool = False) -> tuple[bool, Path | None, str, bool]:
        ks_sources = self._discover_keyboard_shortcuts_sources()
        if not ks_sources:
            return (
                False,
                None,
                "Offline KeyboardShortcuts sources not found under SourcePackages/checkouts/KeyboardShortcuts",
                False,
            )

        ks_hash = self._hash_files(ks_sources, extra=f"{self.target}|ks|{BUNDLE_SHIM_SOURCE}")
        ks_cache = self.cache_root / f"ks_{ks_hash}"
        ks_cache.mkdir(parents=True, exist_ok=True)
        obj_path = ks_cache / "KeyboardShortcuts.o"
        mod_path = ks_cache / "KeyboardShortcuts.swiftmodule"
        shim_path = ks_cache / "BundleShim.swift"

        if not force and obj_path.is_file() and mod_path.is_file():
            return True, ks_cache, "KeyboardShortcuts cache hit", True

        shim_path.write_text(BUNDLE_SHIM_SOURCE, encoding="utf-8")
        cmd = [
            "xcrun",
            "swiftc",
            "-parse-as-library",
            "-whole-module-optimization",
            "-emit-module",
            "-emit-object",
            "-module-name",
            "KeyboardShortcuts",
            "-swift-version",
            "5",
            "-target",
            self.target,
            "-Onone",
            "-emit-module-path",
            str(mod_path),
            "-o",
            str(obj_path),
            *[str(p) for p in ks_sources],
            str(shim_path),
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            _ = self_test
            return (
                False,
                None,
                f"KeyboardShortcuts compilation failed (rc={proc.returncode}): {proc.stderr.strip()[:600]}",
                False,
            )
        return True, ks_cache, "KeyboardShortcuts compiled", False

    def compile_standalone(self, force: bool = False) -> CompileResult:
        """Compile DriverMain.swift + DriverSupport.swift standalone (with empty case stubs)."""
        main_swift = self.driver_dir / "DriverMain.swift"
        support_swift = self.driver_dir / "DriverSupport.swift"
        if not main_swift.is_file() or not support_swift.is_file():
            return CompileResult(
                ok=False,
                binary_path=None,
                status="ERROR",
                message="DriverMain.swift or DriverSupport.swift missing",
            )

        case_files = sorted((self.driver_dir / "cases").glob("*.swift")) if (self.driver_dir / "cases").is_dir() else []
        # Use real cases/*.swift if none reference Kastor/KeyboardShortcuts, else use empty stub
        use_real_cases = bool(case_files) and all(
            not re.search(r"\b(AppModel|HistoryStore|ClipboardFilter|KastorTheme|L10n|KeyboardShortcuts|StatusBarController)\b", p.read_text(encoding="utf-8", errors="replace"))
            for p in case_files
        )

        sources = [main_swift, support_swift] + (case_files if use_real_cases else [])
        extra = f"{self.target}|standalone|real_cases={use_real_cases}"
        src_hash = self._hash_files(sources, extra=extra)
        out_dir = self.cache_root / f"standalone_{src_hash}"
        out_dir.mkdir(parents=True, exist_ok=True)
        bin_path = out_dir / "kastor_driver_standalone"

        if not force and bin_path.is_file():
            return CompileResult(
                ok=True,
                binary_path=bin_path,
                status="PASS",
                message="Standalone driver cache hit",
                cached=True,
            )

        compile_inputs = [str(p) for p in sources]
        if not use_real_cases:
            stub_path = out_dir / "EmptyCasesStub.swift"
            stub_path.write_text(EMPTY_CASES_STUB, encoding="utf-8")
            compile_inputs.append(str(stub_path))

        cmd = [
            "xcrun",
            "swiftc",
            "-parse-as-library",
            "-swift-version",
            "5",
            "-target",
            self.target,
            "-warnings-as-errors",
            "-framework",
            "AppKit",
            "-framework",
            "ApplicationServices",
            "-framework",
            "SwiftUI",
            *compile_inputs,
            "-o",
            str(bin_path),
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            return CompileResult(
                ok=False,
                binary_path=None,
                status="ERROR",
                message=f"Standalone Swift driver compilation failed (rc={proc.returncode})",
                stderr=proc.stderr.strip(),
            )
        return CompileResult(
            ok=True,
            binary_path=bin_path,
            status="PASS",
            message="Standalone Swift driver compiled cleanly",
            cached=False,
        )

    def compile_full(self, self_test: bool = False, force: bool = False) -> CompileResult:
        """Compile Kastor/**/*.swift (sans @main) + KeyboardShortcuts + E2ETests/swift_driver."""
        driver_sources = self._discover_driver_sources()
        if not driver_sources:
            return CompileResult(
                ok=False,
                binary_path=None,
                status="ERROR",
                message="No Swift driver sources found under E2ETests/swift_driver",
            )

        kastor_sources = self._discover_kastor_sources()
        if not kastor_sources:
            return CompileResult(
                ok=False,
                binary_path=None,
                status="PENDING_IMPL" if self_test else "FAIL",
                message="Kastor/ Swift sources not found yet",
            )

        ks_ok, ks_cache, ks_msg, _ = self._compile_keyboard_shortcuts(self_test=self_test, force=force)
        if not ks_ok or ks_cache is None:
            return CompileResult(
                ok=False,
                binary_path=None,
                status="PENDING_IMPL" if self_test else "FAIL",
                message=ks_msg,
            )

        ks_obj = ks_cache / "KeyboardShortcuts.o"
        full_hash = self._hash_files(
            kastor_sources + driver_sources,
            extra=f"{self.target}|full|{ks_cache.name}",
        )
        out_dir = self.cache_root / f"full_{full_hash}"
        out_dir.mkdir(parents=True, exist_ok=True)
        bin_path = out_dir / "kastor_driver"

        if not force and bin_path.is_file():
            return CompileResult(
                ok=True,
                binary_path=bin_path,
                status="PASS",
                message="Full Kastor Swift driver cache hit",
                cached=True,
            )

        fw_flags: list[str] = []
        for fw in FRAMEWORKS:
            fw_flags.extend(["-framework", fw])

        cmd = [
            "xcrun",
            "swiftc",
            "-parse-as-library",
            "-swift-version",
            "5",
            "-target",
            self.target,
            "-warnings-as-errors",
            "-I",
            str(ks_cache),
            *fw_flags,
            str(ks_obj),
            *[str(p) for p in kastor_sources],
            *[str(p) for p in driver_sources],
            "-o",
            str(bin_path),
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            stderr_text = proc.stderr.strip()
            return CompileResult(
                ok=False,
                binary_path=None,
                status="PENDING_IMPL" if self_test else "FAIL",
                message=f"Swift driver + Kastor link failed (rc={proc.returncode}): {stderr_text[:500]}",
                stderr=stderr_text,
            )

        return CompileResult(
            ok=True,
            binary_path=bin_path,
            status="PASS",
            message=f"Full Swift driver compiled cleanly ({len(kastor_sources)} Kastor files)",
            cached=False,
        )

    def _run_binary(self, binary_path: Path, args: list[str], timeout: float = 120.0) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="kastor_driver_home_") as tmp_home:
            env = os.environ.copy()
            env["HOME"] = tmp_home
            env["KASTOR_E2E_ASSETS_DIR"] = str(self.reference_assets_dir)
            return subprocess.run(
                [str(binary_path), *args],
                capture_output=True,
                text=True,
                env=env,
                timeout=timeout,
                check=False,
            )

    @staticmethod
    def _parse_json_lines(stdout: str) -> list[dict[str, Any]]:
        results: list[dict[str, Any]] = []
        for raw_line in stdout.splitlines():
            line = raw_line.strip()
            if not line:
                continue
            results.append(json.loads(line))
        return results

    def run_self_test(self, standalone: bool = True) -> TestOutcome:
        start = time.perf_counter()
        comp = self.compile_standalone() if standalone else self.compile_full(self_test=True)
        if not comp.ok or comp.binary_path is None:
            return TestOutcome(
                status=comp.status,
                duration_ms=(time.perf_counter() - start) * 1000.0,
                summary=comp.message,
                details={"stderr": comp.stderr} if comp.stderr else None,
            )

        proc = self._run_binary(comp.binary_path, ["--self-test"])
        try:
            lines = self._parse_json_lines(proc.stdout)
        except Exception as exc:
            return TestOutcome(
                status="ERROR",
                duration_ms=(time.perf_counter() - start) * 1000.0,
                summary=f"Failed to parse Swift driver --self-test output: {exc}",
                details={"stdout": proc.stdout, "stderr": proc.stderr},
            )

        if not lines:
            return TestOutcome(
                status="ERROR",
                duration_ms=(time.perf_counter() - start) * 1000.0,
                summary="Swift driver --self-test produced no JSON output",
                details={"returncode": proc.returncode, "stderr": proc.stderr},
            )

        entry = lines[-1]
        status: TestStatus = entry.get("status", "ERROR")
        return TestOutcome(
            status=status,
            duration_ms=(time.perf_counter() - start) * 1000.0,
            summary=str(entry.get("message", comp.message)),
            details={"metrics": entry.get("metrics", {}), "cached": comp.cached},
        )

    def probe_kastor_link(self, self_test: bool = True) -> TestOutcome:
        """Probe full compilation & --list against Kastor/ + KeyboardShortcuts."""
        start = time.perf_counter()
        comp = self.compile_full(self_test=self_test)
        if not comp.ok or comp.binary_path is None:
            return TestOutcome(
                status=comp.status,
                duration_ms=(time.perf_counter() - start) * 1000.0,
                summary=comp.message,
                details={"stderr": comp.stderr[:1000]} if comp.stderr else None,
            )

        proc = self._run_binary(comp.binary_path, ["--list"])
        if proc.returncode != 0:
            return TestOutcome(
                status="ERROR",
                duration_ms=(time.perf_counter() - start) * 1000.0,
                summary=f"Swift driver --list exited {proc.returncode}",
                details={"stderr": proc.stderr},
            )
        try:
            cases = json.loads(proc.stdout)
        except Exception as exc:
            return TestOutcome(
                status="ERROR",
                duration_ms=(time.perf_counter() - start) * 1000.0,
                summary=f"Swift driver --list returned invalid JSON: {exc}",
                details={"stdout": proc.stdout},
            )

        return TestOutcome(
            status="PASS",
            duration_ms=(time.perf_counter() - start) * 1000.0,
            summary=f"{comp.message}; registered Swift cases={len(cases)}",
            details={"registered_swift_cases": len(cases), "cached": comp.cached},
        )

    def run_case(self, case_id: str, self_test: bool = False) -> TestOutcome:
        start = time.perf_counter()
        comp = self.compile_full(self_test=self_test)
        if not comp.ok or comp.binary_path is None:
            return TestOutcome(
                status=comp.status,
                duration_ms=(time.perf_counter() - start) * 1000.0,
                summary=comp.message,
                details={"stderr": comp.stderr[:1000]} if comp.stderr else None,
            )

        proc = self._run_binary(comp.binary_path, ["--case", case_id])
        try:
            lines = self._parse_json_lines(proc.stdout)
        except Exception as exc:
            return TestOutcome(
                status="ERROR",
                duration_ms=(time.perf_counter() - start) * 1000.0,
                summary=f"Invalid JSON from driver for {case_id}: {exc}",
                details={"stdout": proc.stdout, "stderr": proc.stderr},
            )

        if not lines:
            return TestOutcome(
                status="ERROR",
                duration_ms=(time.perf_counter() - start) * 1000.0,
                summary=f"No output from driver for {case_id} (rc={proc.returncode})",
                details={"stderr": proc.stderr},
            )

        entry = lines[-1]
        return TestOutcome(
            status=entry.get("status", "ERROR"),
            duration_ms=float(entry.get("duration_ms", (time.perf_counter() - start) * 1000.0)),
            summary=str(entry.get("message", "")),
            details={"metrics": entry.get("metrics", {})},
        )

    def run_batch(self, case_ids: list[str], self_test: bool = False) -> dict[str, TestOutcome]:
        if not case_ids:
            return {}
        start = time.perf_counter()
        comp = self.compile_full(self_test=self_test)
        if not comp.ok or comp.binary_path is None:
            elapsed = (time.perf_counter() - start) * 1000.0
            return {
                cid: TestOutcome(
                    status=comp.status,
                    duration_ms=elapsed,
                    summary=comp.message,
                    details={"stderr": comp.stderr[:1000]} if comp.stderr else None,
                )
                for cid in case_ids
            }

        proc = self._run_binary(comp.binary_path, ["--batch", ",".join(case_ids)], timeout=300.0)
        outcomes: dict[str, TestOutcome] = {}
        try:
            for entry in self._parse_json_lines(proc.stdout):
                cid = str(entry.get("id", ""))
                if cid:
                    outcomes[cid] = TestOutcome(
                        status=entry.get("status", "ERROR"),
                        duration_ms=float(entry.get("duration_ms", 0.0)),
                        summary=str(entry.get("message", "")),
                        details={"metrics": entry.get("metrics", {})},
                    )
        except Exception as exc:
            err_msg = f"Failed to parse batch NDJSON output: {exc}"
            for cid in case_ids:
                outcomes.setdefault(
                    cid,
                    TestOutcome(status="ERROR", duration_ms=0.0, summary=err_msg),
                )
            return outcomes

        for cid in case_ids:
            if cid not in outcomes:
                outcomes[cid] = TestOutcome(
                    status="ERROR",
                    duration_ms=0.0,
                    summary=f"Missing output for case {cid} (rc={proc.returncode})",
                    details={"stderr": proc.stderr[:500]} if proc.stderr else None,
                )
        return outcomes
