from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from .base import EXPECTED_FORMAL_OUTPUTS as EXPECTED_FORMAL_OUTPUTS
from .base import UnsupportedSpssRunner
from .macos import MacOSSpssRunner
from .windows import WindowsSpssRunner


def get_runner(platform_name: str | None = None):
    selected = platform_name or sys.platform
    if selected == "win32":
        return WindowsSpssRunner()
    if selected == "darwin":
        return MacOSSpssRunner()
    return UnsupportedSpssRunner(selected)


def spss_status(platform_name: str | None = None) -> dict[str, Any]:
    return get_runner(platform_name).status()


def run_spss_automatically(
    syntax_path: Path,
    output_dir: Path,
    timeout_seconds: int = 180,
    platform_name: str | None = None,
) -> dict[str, Any]:
    return get_runner(platform_name).run(syntax_path, output_dir, timeout_seconds)


def public_spss_status(status: dict[str, Any]) -> dict[str, Any]:
    """Return the fields safe to expose through the loopback API."""

    allowed = {
        "installed",
        "licenseState",
        "executionMode",
        "note",
        "platform",
        "integrationVerified",
    }
    return {key: value for key, value in status.items() if key in allowed}
