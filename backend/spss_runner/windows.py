from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Any, Iterable

from .base import marker_result


CMD_UNSAFE_CHARACTERS = frozenset('%!\r\n"')


def validate_cmd_path(path: str | Path, *, label: str) -> str:
    """Return a path that is safe to pass through the Windows command parser.

    IBM exposes its external Python launcher as a `.bat` file, so `cmd.exe`
    remains part of this boundary.  Spaces, Unicode, and apostrophes are valid
    and are passed through the native Unicode command line.  Characters that
    trigger percent/delayed expansion or terminate a quoted argument are
    rejected explicitly instead of being silently rewritten. Other command
    metacharacters (including parentheses) are safe inside the quoted
    arguments built by :func:`build_cmd_invocation`.
    """

    value = str(path)
    found = sorted({character for character in value if character in CMD_UNSAFE_CHARACTERS})
    if found:
        rendered = " ".join(repr(character) for character in found)
        raise ValueError(f"{label} contains Windows command characters that cannot be used safely: {rendered}")
    return value


def build_cmd_invocation(
    command_processor: str | Path,
    launcher: str | Path,
    driver: str | Path,
) -> list[str]:
    """Build one quoted ``cmd.exe`` command without invoking a shell in Python."""

    cmd = validate_cmd_path(command_processor, label="System cmd.exe path")
    batch = validate_cmd_path(launcher, label="IBM SPSS launcher path")
    script = validate_cmd_path(driver, label="Survey Data Workbench job path")
    command = f'call "{batch}" "{script}"'
    return [cmd, "/d", "/v:off", "/s", "/c", command]


def system_directory_path() -> Path:
    """Ask Windows for its system directory without trusting process environment."""

    if os.name != "nt":
        raise OSError("The trusted Windows system directory is only available on Windows")
    import ctypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.GetSystemDirectoryW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32]
    kernel32.GetSystemDirectoryW.restype = ctypes.c_uint32
    buffer = ctypes.create_unicode_buffer(32768)
    length = kernel32.GetSystemDirectoryW(buffer, len(buffer))
    if length == 0 or length >= len(buffer):
        error = ctypes.get_last_error()
        raise OSError(error, "Windows did not return a usable trusted system directory")
    return Path(buffer.value)


def system_cmd_path() -> Path:
    """Resolve the operating-system command processor without trusting COMSPEC/SystemRoot."""

    candidate = system_directory_path() / "cmd.exe"
    if not candidate.is_file():
        raise OSError(f"The trusted Windows command processor was not found at {candidate}")
    validate_cmd_path(candidate, label="System cmd.exe path")
    return candidate


def _version_key(path: Path) -> tuple[int, ...]:
    numbers = []
    for part in path.name.replace("-", ".").split("."):
        if part.isdigit():
            numbers.append(int(part))
    return tuple(numbers) or (0,)


def _registry_install_locations() -> list[Path]:
    if os.name != "nt":
        return []
    try:
        import winreg
    except ImportError:
        return []

    locations: list[Path] = []
    roots = (winreg.HKEY_LOCAL_MACHINE, winreg.HKEY_CURRENT_USER)
    keys = (
        r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    )
    for root in roots:
        for key_name in keys:
            try:
                key = winreg.OpenKey(root, key_name)
            except OSError:
                continue
            with key:
                for index in range(winreg.QueryInfoKey(key)[0]):
                    try:
                        child_name = winreg.EnumKey(key, index)
                        child = winreg.OpenKey(key, child_name)
                    except OSError:
                        continue
                    with child:
                        try:
                            display_name = str(winreg.QueryValueEx(child, "DisplayName")[0])
                            install_location = str(winreg.QueryValueEx(child, "InstallLocation")[0])
                        except OSError:
                            continue
                    if "IBM SPSS Statistics" in display_name and install_location:
                        locations.append(Path(install_location))
    return locations


def default_candidate_homes() -> list[Path]:
    candidates: list[Path] = []
    for variable in ("SPSS_HOME", "SPSS_APP_PATH"):
        configured = os.environ.get(variable)
        if configured:
            candidates.append(Path(configured).expanduser())
    candidates.extend(_registry_install_locations())

    for variable in ("ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"):
        program_files = os.environ.get(variable)
        if not program_files:
            continue
        bases = (
            Path(program_files) / "IBM" / "SPSS Statistics",
            Path(program_files) / "IBM" / "SPSS" / "Statistics",
        )
        for base in bases:
            candidates.append(base)
            if base.is_dir():
                candidates.extend(sorted((path for path in base.iterdir() if path.is_dir()), key=_version_key, reverse=True))
    return candidates


def detect_windows_spss(candidate_homes: Iterable[Path] | None = None) -> dict[str, Any]:
    seen: set[str] = set()
    for raw_home in candidate_homes or default_candidate_homes():
        home = raw_home.expanduser().resolve(strict=False)
        normalized = str(home).casefold()
        if normalized in seen:
            continue
        seen.add(normalized)
        batch_candidates = (
            home / "statisticspython3.bat",
            home / "bin" / "statisticspython3.bat",
        )
        batch = next((path for path in batch_candidates if path.is_file()), None)
        python = home / "Python3" / "python.exe"
        if batch is not None and python.is_file():
            return {
                "installed": True,
                "homePath": str(home),
                "pythonLauncher": str(batch),
                "bundledPython": str(python),
                "licenseState": "unverified",
                "executionMode": "IBM SPSS external Python + spss.Submit()",
                "platform": "windows",
                "integrationVerified": False,
                "note": "已检测到 IBM SPSS Statistics；只有真实执行并验证输出后才确认许可证和集成状态。",
            }
    return {
        "installed": False,
        "licenseState": "unavailable",
        "executionMode": "Python 预检模式",
        "platform": "windows",
        "integrationVerified": False,
        "note": "未检测到用户自行安装的 IBM SPSS Statistics Python launcher；本应用不会推断许可证状态，仍可生成预检、语法和下载包。",
    }


class WindowsSpssRunner:
    def __init__(self, candidate_homes: Iterable[Path] | None = None) -> None:
        self.candidate_homes = list(candidate_homes) if candidate_homes is not None else None

    def status(self) -> dict[str, Any]:
        return detect_windows_spss(self.candidate_homes)

    def run(self, syntax_path: Path, output_dir: Path, timeout_seconds: int = 180) -> dict[str, Any]:
        del syntax_path
        status = self.status()
        if not status["installed"]:
            return {"state": "unavailable", "message": status["note"]}

        driver = output_dir / "run_with_spss_external.py"
        if not driver.is_file():
            return {
                "state": "failed",
                "message": "缺少 Windows SPSS external Python driver；不会报告执行成功。",
            }

        marker = output_dir / "spss_python_status.json"
        marker.unlink(missing_ok=True)
        try:
            command_processor = system_cmd_path()
            invocation = build_cmd_invocation(
                command_processor,
                status["pythonLauncher"],
                driver,
            )
        except (OSError, ValueError) as error:
            return {
                "state": "failed",
                "message": f"IBM SPSS Windows runner 拒绝了不安全或不可用的启动路径：{error}",
            }

        process: subprocess.Popen[str] | None = None
        try:
            process = subprocess.Popen(
                invocation,
                cwd=output_dir,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            stdout, stderr = process.communicate(timeout=timeout_seconds)
            return_code = process.returncode
        except subprocess.TimeoutExpired:
            tree_termination_verified = False
            termination_error = ""
            if process is not None:
                try:
                    taskkill = system_directory_path() / "taskkill.exe"
                except OSError as error:
                    taskkill = None
                    termination_error = str(error)
                if taskkill is not None and taskkill.is_file():
                    try:
                        terminated = subprocess.run(
                            [str(taskkill), "/PID", str(process.pid), "/T", "/F"],
                            text=True,
                            capture_output=True,
                            timeout=30,
                            check=False,
                            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                        )
                        tree_termination_verified = terminated.returncode == 0
                        if not tree_termination_verified:
                            termination_error = (
                                f"taskkill exited {terminated.returncode}: "
                                f"{(terminated.stderr or terminated.stdout)[-500:]}"
                            )
                    except (OSError, subprocess.TimeoutExpired) as error:
                        termination_error = str(error)
                elif not termination_error:
                    termination_error = "trusted Windows taskkill.exe was unavailable"
                if process.poll() is None:
                    try:
                        process.kill()
                    except OSError as error:
                        termination_error = f"{termination_error}; direct kill failed: {error}"
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired as error:
                    tree_termination_verified = False
                    termination_error = f"{termination_error}; root process remained alive: {error}"
                if process.stdout is not None:
                    process.stdout.close()
                if process.stderr is not None:
                    process.stderr.close()
            return {
                "state": "timeout",
                "message": (
                    "IBM SPSS Windows 执行超时；进程树已由 Windows taskkill 确认终止，不会报告正式执行成功。"
                    if tree_termination_verified
                    else "IBM SPSS Windows 执行超时，且无法确认整个进程树已终止；不会报告正式执行成功。"
                ),
                "details": {
                    "treeTerminationVerified": tree_termination_verified,
                    "terminationError": termination_error[-1000:],
                },
            }
        except OSError as error:
            return {"state": "failed", "message": f"无法启动 IBM SPSS Windows runner：{error}"}

        result = marker_result(output_dir, success_message="IBM SPSS Windows 正式文件已生成并通过格式完整性解析；语义验证仍需两套获授权环境。")
        if return_code != 0 and result.get("state") == "complete":
            return {
                "state": "failed",
                "message": "IBM SPSS driver 返回非零退出码；不会报告正式执行成功。",
                "details": {"returnCode": return_code},
            }
        if result.get("state") != "complete":
            details = dict(result.get("details") or {})
            details.update(
                {
                    "returnCode": return_code,
                    "stdout": stdout[-2000:],
                    "stderr": stderr[-2000:],
                }
            )
            result["details"] = details
        return result
