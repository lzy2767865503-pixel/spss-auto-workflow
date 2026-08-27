from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any

from .base import marker_result


class MacOSSpssRunner:
    def __init__(self) -> None:
        self.app_path = Path(
            os.environ.get(
                "SPSS_APP_PATH",
                "/Applications/IBM SPSS Statistics/IBM SPSS Statistics.app",
            )
        ).expanduser()
        self.binary_path = self.app_path / "Contents/MacOS/stats"

    def status(self) -> dict[str, Any]:
        installed = self.app_path.exists() and self.binary_path.exists()
        return {
            "installed": installed,
            "licenseState": "unverified" if installed else "unavailable",
            "appPath": str(self.app_path) if installed else None,
            "binaryPath": str(self.binary_path) if installed else None,
            "executionMode": "SPSS 内置 Python + spss.Submit()" if installed else "Python 预检模式",
            "platform": "macos",
            "integrationVerified": False,
            "note": (
                "已检测到 IBM SPSS Statistics；只有真实执行并验证输出后才确认许可证和集成状态。"
                if installed
                else "未检测到 IBM SPSS Statistics，仍可生成语法、预检表和下载包。"
            ),
        }

    def run(self, syntax_path: Path, output_dir: Path, timeout_seconds: int = 180) -> dict[str, Any]:
        status = self.status()
        if not status["installed"]:
            return {"state": "unavailable", "message": status["note"]}

        marker = output_dir / "spss_python_status.json"
        marker.unlink(missing_ok=True)
        try:
            launch = subprocess.run(
                ["open", "-a", str(self.app_path), str(syntax_path)],
                text=True,
                capture_output=True,
                timeout=20,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            return {"state": "failed", "message": f"SPSS 启动失败：{error}"}
        if launch.returncode != 0:
            return {"state": "failed", "message": launch.stderr.strip() or "SPSS 启动失败"}

        apple_script = """
tell application "IBM SPSS Statistics" to activate
delay 3
tell application "System Events"
  tell process "IBM SPSS Statistics"
    if not ((exists menu "Run" of menu bar 1) or (exists menu "运行" of menu bar 1)) then
      return "STARTUP_BLOCKED"
    end if
    if exists menu "Run" of menu bar 1 then
      try
        click menu item "All" of menu "Run" of menu bar 1
      on error
        keystroke "r" using command down
      end try
    else
      try
        click menu item "全部" of menu "运行" of menu bar 1
      on error
        keystroke "r" using command down
      end try
    end if
    return "RUN_SUBMITTED"
  end tell
end tell
"""
        try:
            automation = subprocess.run(
                ["osascript", "-e", apple_script],
                text=True,
                capture_output=True,
                timeout=30,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            return {"state": "failed", "message": f"SPSS 自动操作失败：{error}"}
        if automation.returncode != 0:
            return {
                "state": "permission_required",
                "message": "SPSS 已打开，但 macOS 未允许自动点击。请允许辅助功能权限后重试。",
                "details": automation.stderr.strip()[-2000:],
            }
        if "STARTUP_BLOCKED" in automation.stdout:
            return {
                "state": "activation_required",
                "message": "SPSS 已安装，但被登录、激活或启动对话框阻塞。",
            }

        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            if marker.exists():
                try:
                    json.loads(marker.read_text(encoding="utf-8"))
                except json.JSONDecodeError:
                    time.sleep(1)
                    continue
                return marker_result(output_dir, success_message="IBM SPSS 正式文件已生成并通过格式完整性解析；语义验证仍需两套获授权环境。")
            time.sleep(1)
        return {
            "state": "timeout",
            "message": "SPSS 已启动，但等待超时；不会报告正式执行成功。",
        }
