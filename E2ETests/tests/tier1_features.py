"""Tier 1 feature coverage tests (populated in E2E-M2)."""

from __future__ import annotations

from lib.models import RunContext, TestSpec


def register_tests(ctx: RunContext) -> list[TestSpec]:
    """Register Tier 1 feature tests."""
    _ = ctx
    return []
