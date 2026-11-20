#!/usr/bin/env python3
"""Kastor E2E test runner and harness self-test orchestrator."""

from __future__ import annotations

import argparse
import importlib
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

E2E_ROOT = Path(__file__).resolve().parent
PROJECT_ROOT = E2E_ROOT.parent
if str(E2E_ROOT) not in sys.path:
    sys.path.insert(0, str(E2E_ROOT))

from lib import bundle_checks
from lib.models import (
    DEFAULT_APP_PATH,
    DEFAULT_OUTPUTS_DIR,
    DEFAULT_REFERENCE_ASSETS_DIR,
    FEATURES,
    TIER_THRESHOLDS,
    VALID_STATUSES,
    RunContext,
    TestOutcome,
    TestSpec,
)
from lib.swift_bridge import SwiftBridge

TIER_MODULES: dict[int, str] = {
    1: "tests.tier1_features",
    2: "tests.tier2_boundaries",
    3: "tests.tier3_pairwise",
    4: "tests.tier4_scenarios",
}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Kastor E2E Test Runner")
    parser.add_argument(
        "--tier",
        choices=("1", "2", "3", "4", "all"),
        default="all",
        help="Select test tier to run (default: all)",
    )
    parser.add_argument(
        "--app",
        type=Path,
        default=DEFAULT_APP_PATH,
        help=f"Path to Kastor.app (default: {DEFAULT_APP_PATH})",
    )
    parser.add_argument(
        "--json",
        type=Path,
        default=None,
        help="Optional path to write JSON report",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run harness self-test checks (syntax, registry, Swift driver, bundle smoke, strict-mode check)",
    )
    parser.add_argument(
        "--allow-partial-inventory",
        action="store_true",
        help="Only valid with --self-test: allow tier test counts below thresholds during early milestones",
    )
    parser.add_argument(
        "--filter",
        type=str,
        default=None,
        help="Case-insensitive substring filter applied to test id, feature, or title",
    )
    return parser.parse_args(argv)


def selected_tiers_from_arg(tier_arg: str) -> list[int]:
    if tier_arg == "all":
        return [1, 2, 3, 4]
    return [int(tier_arg)]


def discover_tests(ctx: RunContext, tiers: list[int]) -> tuple[list[TestSpec], list[str]]:
    specs: list[TestSpec] = []
    errors: list[str] = []
    seen_ids: set[str] = set()

    for tier in tiers:
        mod_name = TIER_MODULES[tier]
        try:
            mod = importlib.import_module(mod_name)
        except Exception as exc:
            errors.append(f"Failed to import {mod_name}: {exc}")
            continue

        reg_fn = getattr(mod, "register_tests", None)
        if not callable(reg_fn):
            errors.append(f"{mod_name} missing callable register_tests(ctx)")
            continue

        try:
            tier_specs = reg_fn(ctx)
        except Exception as exc:
            errors.append(f"{mod_name}.register_tests(ctx) raised: {exc}")
            continue

        if not isinstance(tier_specs, list):
            errors.append(f"{mod_name}.register_tests(ctx) must return list[TestSpec]")
            continue

        for item in tier_specs:
            if not isinstance(item, TestSpec):
                errors.append(f"{mod_name} yielded non-TestSpec item: {item!r}")
                continue
            if item.tier != tier:
                errors.append(f"Test {item.id} in {mod_name} has mismatched tier {item.tier} != {tier}")
            if item.feature not in FEATURES:
                errors.append(f"Test {item.id} references unknown feature {item.feature!r}")
            if not callable(item.runner):
                errors.append(f"Test {item.id} runner is not callable")
            if item.id in seen_ids:
                errors.append(f"Duplicate test id {item.id!r}")
            seen_ids.add(item.id)
            specs.append(item)

    return specs, errors


def run_test_specs(ctx: RunContext, specs: list[TestSpec]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for spec in specs:
        start = time.perf_counter()
        try:
            outcome = spec.runner(ctx)
            if not isinstance(outcome, TestOutcome) or outcome.status not in VALID_STATUSES:
                outcome = TestOutcome(
                    status="ERROR",
                    duration_ms=(time.perf_counter() - start) * 1000.0,
                    summary=f"Invalid TestOutcome returned by {spec.id}: {outcome!r}",
                )
        except Exception as exc:
            outcome = TestOutcome(
                status="ERROR",
                duration_ms=(time.perf_counter() - start) * 1000.0,
                summary=f"Unhandled exception in {spec.id}: {exc}",
            )
        records.append(
            {
                "id": spec.id,
                "tier": spec.tier,
                "feature": spec.feature,
                "title": spec.title,
                "status": outcome.status,
                "duration_ms": round(outcome.duration_ms, 2),
                "summary": outcome.summary,
                "details": outcome.details,
            }
        )
    return records


def run_self_test_suite(
    ctx: RunContext, args: argparse.Namespace, discovery_errors: list[str]
) -> list[dict[str, Any]]:
    checks: list[dict[str, Any]] = []

    def record(name: str, outcome: TestOutcome) -> None:
        checks.append(
            {
                "name": name,
                "status": outcome.status,
                "duration_ms": round(outcome.duration_ms, 2),
                "summary": outcome.summary,
                "details": outcome.details,
            }
        )

    # 1. Shell syntax check
    t0 = time.perf_counter()
    sh_proc = subprocess.run(
        ["bash", "-n", str(E2E_ROOT / "run_e2e.sh")],
        capture_output=True,
        text=True,
        check=False,
    )
    record(
        "syntax.run_e2e_sh",
        TestOutcome(
            status="PASS" if sh_proc.returncode == 0 else "ERROR",
            duration_ms=(time.perf_counter() - t0) * 1000.0,
            summary="bash -n E2ETests/run_e2e.sh passed" if sh_proc.returncode == 0 else f"bash -n failed: {sh_proc.stderr.strip()}",
        ),
    )

    # 2. Python syntax check
    t0 = time.perf_counter()
    py_files = sorted(
        [E2E_ROOT / "e2e_runner.py"]
        + list((E2E_ROOT / "lib").glob("*.py"))
        + list((E2E_ROOT / "tests").glob("*.py"))
    )
    py_proc = subprocess.run(
        [sys.executable, "-m", "py_compile", *[str(p) for p in py_files]],
        capture_output=True,
        text=True,
        check=False,
    )
    record(
        "syntax.python_compile",
        TestOutcome(
            status="PASS" if py_proc.returncode == 0 else "ERROR",
            duration_ms=(time.perf_counter() - t0) * 1000.0,
            summary=f"py_compile passed on {len(py_files)} Python files"
            if py_proc.returncode == 0
            else f"py_compile failed: {py_proc.stderr.strip()}",
        ),
    )

    # 3. Feature registry F01..F14 & discovery structure
    t0 = time.perf_counter()
    expected_features = [f"F{i:02d}" for i in range(1, 15)]
    missing_features = [fid for fid in expected_features if fid not in FEATURES]
    if missing_features or discovery_errors:
        record(
            "registry.features_and_tiers",
            TestOutcome(
                status="ERROR",
                duration_ms=(time.perf_counter() - t0) * 1000.0,
                summary=f"Registry/discovery errors: missing={missing_features}, discovery={discovery_errors}",
            ),
        )
    else:
        record(
            "registry.features_and_tiers",
            TestOutcome(
                status="PASS",
                duration_ms=(time.perf_counter() - t0) * 1000.0,
                summary="Feature registry F01..F14 and tier modules validated",
            ),
        )

    # 4. Swift driver standalone compile + --self-test
    record("swift_driver.standalone_self_test", ctx.swift_bridge.run_self_test(standalone=True))

    # 5. Swift driver Kastor + KeyboardShortcuts link probe
    record("swift_driver.kastor_link_probe", ctx.swift_bridge.probe_kastor_link(self_test=True))

    # 6. Bundle & reference asset smoke checks (self_test=True => missing targets report PENDING_IMPL, not ERROR)
    record("bundle.app_exists", bundle_checks.check_app_exists(ctx.app_path, self_test=True))
    record("bundle.info_plist", bundle_checks.check_info_plist(ctx.app_path, self_test=True))
    record("bundle.codesign_runtime", bundle_checks.check_codesign_and_runtime(ctx.app_path, self_test=True))
    record("bundle.entitlements", bundle_checks.check_entitlements(ctx.app_path, self_test=True))
    record("bundle.security_gate", bundle_checks.check_security_gate(ctx.project_root, ctx.app_path, self_test=True))
    record("bundle.forbidden_apis", bundle_checks.check_forbidden_apis(ctx.project_root, self_test=True))
    record("bundle.package_resolved", bundle_checks.check_package_resolved(ctx.project_root, self_test=True))
    record("bundle.project_yml", bundle_checks.check_project_yml(ctx.project_root, self_test=True))
    record(
        "assets.icns_vs_dock_ref",
        bundle_checks.check_icns_against_reference(ctx.app_path, ctx.reference_assets_dir, self_test=True),
    )
    record("assets.tray_png_refs", bundle_checks.check_tray_png_references(ctx.reference_assets_dir))
    record(
        "bundle.headless_launch_quit",
        bundle_checks.check_headless_launch_and_quit(ctx.app_path, self_test=True),
    )

    # 7. Verify strict mode rejects incomplete targets / unmet thresholds (non-zero exit)
    t0 = time.perf_counter()
    strict_probe_cmd = [
        sys.executable,
        str(E2E_ROOT / "e2e_runner.py"),
        "--tier",
        "all",
        "--app",
        str(E2E_ROOT / "__nonexistent_strict_probe__.app"),
    ]
    strict_proc = subprocess.run(strict_probe_cmd, capture_output=True, text=True, check=False)
    if strict_proc.returncode != 0:
        record(
            "strict_mode.rejects_incomplete",
            TestOutcome(
                status="PASS",
                duration_ms=(time.perf_counter() - t0) * 1000.0,
                summary=f"Strict mode exited {strict_proc.returncode} on incomplete targets/thresholds",
            ),
        )
    else:
        record(
            "strict_mode.rejects_incomplete",
            TestOutcome(
                status="ERROR",
                duration_ms=(time.perf_counter() - t0) * 1000.0,
                summary="Strict mode unexpectedly exited 0 on incomplete targets",
            ),
        )

    return checks


def compute_report(
    args: argparse.Namespace,
    selected_tiers: list[int],
    specs: list[TestSpec],
    outcomes: list[dict[str, Any]],
    discovery_errors: list[str],
    self_test_checks: list[dict[str, Any]],
) -> tuple[dict[str, Any], int]:
    status_counts = {s: 0 for s in VALID_STATUSES}
    for rec in outcomes:
        status_counts[rec["status"]] = status_counts.get(rec["status"], 0) + 1

    per_tier: dict[str, dict[str, Any]] = {}
    unmet_thresholds: list[str] = []
    for tier in selected_tiers:
        tier_records = [r for r in outcomes if r["tier"] == tier]
        tier_specs = [s for s in specs if s.tier == tier]
        threshold = TIER_THRESHOLDS[tier]
        passed = sum(1 for r in tier_records if r["status"] == "PASS")
        met = len(tier_specs) >= threshold
        if not met:
            unmet_thresholds.append(f"Tier {tier}: {len(tier_specs)} < {threshold}")
        per_tier[str(tier)] = {
            "count": len(tier_specs),
            "executed": len(tier_records),
            "threshold": threshold,
            "threshold_met": met,
            "pass": passed,
            "fail": sum(1 for r in tier_records if r["status"] == "FAIL"),
            "pending_impl": sum(1 for r in tier_records if r["status"] == "PENDING_IMPL"),
            "error": sum(1 for r in tier_records if r["status"] == "ERROR"),
        }

    feature_coverage: dict[str, dict[str, Any]] = {}
    for fid, fmeta in FEATURES.items():
        f_records = [r for r in outcomes if r["feature"] == fid]
        feature_coverage[fid] = {
            "name": fmeta["name"],
            "total": len(f_records),
            "pass": sum(1 for r in f_records if r["status"] == "PASS"),
            "fail": sum(1 for r in f_records if r["status"] == "FAIL"),
            "pending_impl": sum(1 for r in f_records if r["status"] == "PENDING_IMPL"),
            "error": sum(1 for r in f_records if r["status"] == "ERROR"),
        }

    if args.self_test:
        harness_errors = [c for c in self_test_checks if c["status"] == "ERROR"]
        test_errors = [r for r in outcomes if r["status"] == "ERROR"]
        inventory_ok = args.allow_partial_inventory or (not unmet_thresholds)
        ok = (
            not discovery_errors
            and not harness_errors
            and not test_errors
            and inventory_ok
        )
        exit_code = 0 if ok else 1
    else:
        # Strict mode: --allow-partial-inventory is NEVER permitted to bypass strict mode
        bypass_attempted = bool(args.allow_partial_inventory)
        all_passed = (
            len(outcomes) > 0
            and status_counts["PASS"] == len(outcomes)
            and status_counts["FAIL"] == 0
            and status_counts["PENDING_IMPL"] == 0
            and status_counts["ERROR"] == 0
        )
        ok = (
            not bypass_attempted
            and not discovery_errors
            and not unmet_thresholds
            and all_passed
        )
        exit_code = 0 if ok else 1

    report = {
        "mode": "self-test" if args.self_test else "strict",
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "project_root": str(PROJECT_ROOT),
        "app_path": str(args.app),
        "selected_tiers": selected_tiers,
        "allow_partial_inventory": bool(args.allow_partial_inventory),
        "discovery_errors": discovery_errors,
        "unmet_thresholds": unmet_thresholds,
        "summary": {
            "total_discovered": len(specs),
            "total_executed": len(outcomes),
            "counts": status_counts,
            "exit_code": exit_code,
        },
        "per_tier": per_tier,
        "feature_coverage": feature_coverage,
        "self_test_checks": self_test_checks,
        "outcomes": outcomes,
    }
    return report, exit_code


def print_summary(report: dict[str, Any]) -> None:
    mode = report["mode"].upper()
    print(f"=== Kastor E2E Runner ({mode}) ===")
    print(f"App target : {report['app_path']}")
    print(f"Tiers      : {report['selected_tiers']}")

    if report["discovery_errors"]:
        print("Discovery errors:")
        for err in report["discovery_errors"]:
            print(f"  [ERROR] {err}")

    if report["self_test_checks"]:
        print("\nSelf-test checks:")
        for chk in report["self_test_checks"]:
            print(f"  [{chk['status']:12s}] {chk['name']} ({chk['duration_ms']:.1f}ms) - {chk['summary']}")

    print("\nPer-tier summary:")
    for t_key, info in report["per_tier"].items():
        flag = "OK" if info["threshold_met"] else "BELOW_THRESHOLD"
        print(
            f"  Tier {t_key}: {info['count']}/{info['threshold']} ({flag}) | "
            f"PASS={info['pass']} FAIL={info['fail']} PENDING={info['pending_impl']} ERROR={info['error']}"
        )

    counts = report["summary"]["counts"]
    print(
        f"\nTotals: discovered={report['summary']['total_discovered']} "
        f"executed={report['summary']['total_executed']} "
        f"PASS={counts['PASS']} FAIL={counts['FAIL']} "
        f"PENDING_IMPL={counts['PENDING_IMPL']} ERROR={counts['ERROR']}"
    )

    if report["mode"] == "strict" and report["allow_partial_inventory"]:
        print("[ERROR] --allow-partial-inventory is forbidden in strict mode.")
    if report["unmet_thresholds"] and not (report["mode"] == "self-test" and report["allow_partial_inventory"]):
        print("Unmet tier thresholds:", ", ".join(report["unmet_thresholds"]))

    print(f"Result: {'PASS (exit 0)' if report['summary']['exit_code'] == 0 else 'FAIL (exit 1)'}")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    tiers = selected_tiers_from_arg(args.tier)

    if not args.self_test and args.allow_partial_inventory:
        # Strict mode can never be bypassed with --allow-partial-inventory
        pass

    swift_bridge = SwiftBridge(
        project_root=PROJECT_ROOT,
        reference_assets_dir=DEFAULT_REFERENCE_ASSETS_DIR,
    )
    ctx = RunContext(
        project_root=PROJECT_ROOT,
        app_path=args.app,
        outputs_dir=DEFAULT_OUTPUTS_DIR,
        reference_assets_dir=DEFAULT_REFERENCE_ASSETS_DIR,
        swift_bridge=swift_bridge,
        bundle_checks=bundle_checks,
        self_test=bool(args.self_test),
    )

    all_specs, discovery_errors = discover_tests(ctx, tiers)
    if args.filter:
        needle = args.filter.lower()
        filtered_specs = [
            s
            for s in all_specs
            if needle in s.id.lower() or needle in s.feature.lower() or needle in s.title.lower()
        ]
    else:
        filtered_specs = all_specs

    self_test_checks: list[dict[str, Any]] = []
    if args.self_test:
        self_test_checks = run_self_test_suite(ctx, args, discovery_errors)

    outcomes = run_test_specs(ctx, filtered_specs)
    report, exit_code = compute_report(
        args=args,
        selected_tiers=tiers,
        specs=all_specs,
        outcomes=outcomes,
        discovery_errors=discovery_errors,
        self_test_checks=self_test_checks,
    )

    print_summary(report)

    if args.json is not None:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(report, indent=2), encoding="utf-8")

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
