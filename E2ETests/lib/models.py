"""Data models, feature registry, and tier thresholds for Kastor E2E tests."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable, Literal

TestStatus = Literal["PASS", "FAIL", "PENDING_IMPL", "ERROR"]

VALID_STATUSES: tuple[TestStatus, ...] = ("PASS", "FAIL", "PENDING_IMPL", "ERROR")

TIER_THRESHOLDS: dict[int, int] = {
    1: 70,
    2: 70,
    3: 14,
    4: 7,
}

DEFAULT_APP_PATH = Path(
    "/Users/stormtrooper/Documents/Codex/2026-11-19/i-m/outputs/Kastor.app"
)
DEFAULT_OUTPUTS_DIR = Path(
    "/Users/stormtrooper/Documents/Codex/2026-11-19/i-m/outputs"
)
DEFAULT_REFERENCE_ASSETS_DIR = Path(
    "/Users/stormtrooper/.gemini/antigravity/brain/33155495-207e-4af7-8ead-2a11898bf75a/kastor-design"
)

FEATURES: dict[str, dict[str, str]] = {
    "F01": {
        "name": "R1 Rebrand & Build Infra",
        "requirement": "ORIGINAL_REQUEST R1",
        "description": "Kastor naming, com.kastor.clipboard* bundle IDs, Package.resolved 2.4.0, SWIFT_TREAT_WARNINGS_AS_ERRORS",
    },
    "F02": {
        "name": "R1 App Icon (Kastor.icns)",
        "requirement": "ORIGINAL_REQUEST R1",
        "description": "Kastor.icns derived from kastor-dock-1024.png / kastor-icon-1024.png and Info.plist icon config",
    },
    "F03": {
        "name": "R1 System Tray Option D",
        "requirement": "ORIGINAL_REQUEST R1",
        "description": "18x18 / 36x36 Y-up template NSImage matching TrayOption-D-*.png",
    },
    "F04": {
        "name": "R1 Kastor Palette",
        "requirement": "ORIGINAL_REQUEST R1",
        "description": "#EEEAF6 Soluk Lavanta-Parşömen & #1B132B Derin İndigo-Mürdüm across UI",
    },
    "F05": {
        "name": "R2 Security Mode Model & Filtering",
        "requirement": "ORIGINAL_REQUEST R2",
        "description": ".sensitive default vs .normal; 12 secrets, 6 password managers, 3 pasteboard markers, file:/ URLs at capture & storage",
    },
    "F06": {
        "name": "R2 Settings Security Switch",
        "requirement": "ORIGINAL_REQUEST R2",
        "description": "Normal left / Sensitive right switch + hover info explanation",
    },
    "F07": {
        "name": "R3 Low-RAM Encrypted Storage",
        "requirement": "ORIGINAL_REQUEST R3",
        "description": "Metadata-only RAM, AES-GCM per-item payload blobs 0o600, backup exclusion, on-demand decode, popover close cleanup",
    },
    "F08": {
        "name": "R3 24h Auto-Delete Model & Default OFF",
        "requirement": "ORIGINAL_REQUEST R3",
        "description": "false default, >24h retained when OFF, unpinned >24h expired when ON",
    },
    "F09": {
        "name": "R3 Settings Auto-Delete Switch",
        "requirement": "ORIGINAL_REQUEST R3",
        "description": "ON/OFF switch + hover info explaining 24h deletion limits RAM usage",
    },
    "F10": {
        "name": "R3 Range Deletion",
        "requirement": "ORIGINAL_REQUEST R3",
        "description": "Today, Yesterday, last week, all time manual delete preserving pinned & out-of-range items",
    },
    "F11": {
        "name": "R4 12-Language In-App Localization",
        "requirement": "ORIGINAL_REQUEST R4",
        "description": "en default; en, tr, es, fr, de, it, pt, ja, zh, ko, ru, ar; .ar RTL; live UI updates; zero missing keys",
    },
    "F12": {
        "name": "R5 Item Pinning",
        "requirement": "ORIGINAL_REQUEST R5",
        "description": "Right-edge hover pin/unpin icon, top anchor, duplicate preservation, expiry & bulk delete survival, unpin/individual delete",
    },
    "F13": {
        "name": "R5 Toggleable Search Bar",
        "requirement": "ORIGINAL_REQUEST R5",
        "description": "Hidden by default, search toggle button immediately left of Settings button in footer",
    },
    "F14": {
        "name": "Signed Release Kastor.app, Security Gate & Launch",
        "requirement": "ORIGINAL_REQUEST R1 & Acceptance Criteria",
        "description": "LSUIElement, Hardened Runtime, single Sandbox entitlement, scripts/security-gate.sh, zero forbidden APIs, launch & clean quit",
    },
}


@dataclass(slots=True)
class TestOutcome:
    status: TestStatus
    duration_ms: float
    summary: str
    details: dict[str, Any] | None = None

    def to_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        payload["duration_ms"] = round(self.duration_ms, 2)
        return payload


@dataclass(slots=True)
class RunContext:
    project_root: Path
    app_path: Path
    outputs_dir: Path
    reference_assets_dir: Path
    swift_bridge: Any
    bundle_checks: Any
    self_test: bool = False


@dataclass(slots=True)
class TestSpec:
    id: str
    tier: int
    feature: str
    title: str
    runner: Callable[[RunContext], TestOutcome]
    metadata: dict[str, Any] = field(default_factory=dict)
