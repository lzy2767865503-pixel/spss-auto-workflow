from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from importlib import metadata
from pathlib import Path
from typing import Iterable


LICENSE_FILE = re.compile(r"^(licen[cs]e|copying|notice|copyright)(\..*)?$", re.IGNORECASE)
EXPECTED_PYTHON = (3, 12, 10)
EXPECTED_DOTNET_SDK = "8.0.424"
EXPECTED_DOTNET_RUNTIME = "8.0.30"
EXPECTED_DOTNET_TARGET = "net8.0-windows10.0.19041"
EXPECTED_DOTNET_RID = "win-x64"
EXPECTED_WEBVIEW2 = "1.0.4129.50"
EXPECTED_WEBVIEW2_LOCK_RANGE = f"[{EXPECTED_WEBVIEW2}, {EXPECTED_WEBVIEW2}]"


def normalized(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\r", "\n").strip()


def read_text(path: Path) -> str:
    try:
        return normalized(path.read_text(encoding="utf-8"))
    except UnicodeDecodeError:
        return normalized(path.read_text(encoding="latin-1"))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_regular_file(path: Path, label: str) -> Path:
    if path.is_symlink():
        raise RuntimeError(f"{label} must not be a symbolic link: {path}")
    resolved = path.resolve(strict=True)
    if not resolved.is_file() or resolved.stat().st_size <= 0:
        raise RuntimeError(f"{label} is not one non-empty regular file: {resolved}")
    return resolved


def locked_webview_entry(lock: object) -> dict[str, object]:
    if not isinstance(lock, dict):
        raise RuntimeError("NuGet lock must be a JSON object")
    targets = lock.get("dependencies")
    expected_targets = {
        EXPECTED_DOTNET_TARGET,
        f"{EXPECTED_DOTNET_TARGET}/{EXPECTED_DOTNET_RID}",
    }
    if not isinstance(targets, dict) or set(targets) != expected_targets:
        raise RuntimeError(
            "NuGet lock must contain only the exact framework and win-x64 runtime targets"
        )

    entries: list[dict[str, object]] = []
    for target_name in sorted(expected_targets):
        target = targets[target_name]
        if not isinstance(target, dict):
            raise RuntimeError(f"NuGet lock target {target_name} must be an object")
        webview_lock = target.get("Microsoft.Web.WebView2")
        if not isinstance(webview_lock, dict) or (
            webview_lock.get("type") != "Direct"
            or webview_lock.get("requested") != EXPECTED_WEBVIEW2_LOCK_RANGE
            or webview_lock.get("resolved") != EXPECTED_WEBVIEW2
            or not re.fullmatch(
                r"[A-Za-z0-9+/]{40,}={0,2}", str(webview_lock.get("contentHash", ""))
            )
        ):
            raise RuntimeError(
                f"NuGet lock target {target_name} does not bind exact WebView2 version/content hash"
            )
        entries.append(webview_lock)
    if entries[0] != entries[1]:
        raise RuntimeError("NuGet framework and runtime targets bind different WebView2 packages")
    return entries[0]


def canonical_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def locked_requirements(lock_file: Path) -> dict[str, tuple[str, str]]:
    locked: dict[str, tuple[str, str]] = {}
    for raw in lock_file.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", "-r ")):
            continue
        match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([^\s;]+)", line)
        if not match:
            raise RuntimeError(f"Unpinned Python requirement in {lock_file.name}: {line}")
        requested, version = match.groups()
        canonical = canonical_name(requested)
        existing = locked.get(canonical)
        if existing and existing[1] != version:
            raise RuntimeError(f"Conflicting exact Python requirement in {lock_file.name}: {requested}")
        locked[canonical] = (requested, version)
    if not locked:
        raise RuntimeError(f"No exact Python requirements found in {lock_file}")
    return locked


def distribution_license_files(distribution: metadata.Distribution) -> list[tuple[str, str]]:
    values: list[tuple[str, str]] = []
    for relative in distribution.files or []:
        if not LICENSE_FILE.match(Path(str(relative)).name):
            continue
        located = Path(distribution.locate_file(relative))
        if located.is_symlink():
            raise RuntimeError(f"Python distribution license source is a symbolic link: {located}")
        if located.is_file():
            values.append((str(relative).replace("\\", "/"), read_text(located)))
    return sorted(set(values))


def project_url(distribution: metadata.Distribution) -> str:
    for value in distribution.metadata.get_all("Project-URL") or []:
        label, _, url = value.partition(",")
        if label.strip().lower() in {"source", "homepage", "repository"} and url.strip():
            return url.strip()
    return distribution.metadata.get("Home-page", "").strip()


def python_runtime_section(publish: Path) -> str:
    if sys.version_info[:3] != EXPECTED_PYTHON:
        raise RuntimeError(f"Notices must run under exact Python 3.12.10, not {sys.version.split()[0]}")
    runtime_candidates = [
        Path(sys.base_prefix) / "LICENSE.txt",
        Path(sys.base_prefix) / "LICENSE",
        Path(sys.base_prefix) / "Doc" / "license.rst",
    ]
    runtime_licenses = [require_regular_file(path, "Python runtime license") for path in runtime_candidates if path.is_file()]
    if not runtime_licenses:
        raise RuntimeError(f"Python {sys.version.split()[0]} runtime license was not found under {sys.base_prefix}")
    bundled = [path for path in publish.rglob("python312.dll") if path.is_file() and not path.is_symlink()]
    if len(bundled) != 1:
        raise RuntimeError(f"Expected one bundled python312.dll in final publish output; found {len(bundled)}")
    lines = [
        f"## CPython {sys.version.split()[0]} runtime and standard library",
        "",
        "License source: the exact Python installation used by PyInstaller.",
        f"Bundled asset: `{bundled[0].relative_to(publish).as_posix()}`",
        f"Bundled asset SHA-256: `{sha256(bundled[0])}`",
    ]
    for license_path in runtime_licenses:
        lines.extend(
            [
                "",
                f"### Verbatim CPython license: {license_path.name}",
                f"Source SHA-256: `{sha256(license_path)}`",
                "",
                read_text(license_path),
            ]
        )
    return "\n".join(lines)


def python_sections(repo: Path) -> Iterable[str]:
    requirements: dict[str, tuple[str, str]] = {}
    for lock_file in (repo / "requirements.lock.txt", repo / "requirements-build.txt"):
        for canonical, value in locked_requirements(lock_file).items():
            if canonical in requirements and requirements[canonical][1] != value[1]:
                raise RuntimeError(f"Conflicting exact Python versions across lock files for {value[0]}")
            requirements[canonical] = value

    installed: dict[str, metadata.Distribution] = {}
    for distribution in metadata.distributions():
        installed_name = str(distribution.metadata.get("Name", "")).strip()
        if not installed_name:
            raise RuntimeError("An installed Python distribution has no canonical package name")
        canonical = canonical_name(installed_name)
        if canonical in installed:
            raise RuntimeError(f"Duplicate installed Python distribution metadata: {installed_name}")
        installed[canonical] = distribution
    missing = sorted(set(requirements) - set(installed))
    unexpected = sorted(set(installed) - set(requirements))
    if missing:
        raise RuntimeError(f"Locked Python distribution is not installed: {missing[0]}")
    if unexpected:
        raise RuntimeError(
            f"Installed Python distribution is absent from the exact lock files: {unexpected[0]}"
        )

    seen: set[str] = set()
    for canonical_requested, (requested, expected_version) in sorted(requirements.items()):
        distribution = installed[canonical_requested]
        canonical = canonical_name(str(distribution.metadata.get("Name", requested)))
        if canonical != canonical_requested or distribution.version != expected_version:
            raise RuntimeError(
                f"Installed Python distribution {requested} is {distribution.version}, expected exact {expected_version}"
            )
        if canonical in seen:
            continue
        seen.add(canonical)
        name = distribution.metadata.get("Name", requested)
        expression = distribution.metadata.get("License-Expression", "").strip()
        raw_license = distribution.metadata.get("License", "").strip()
        files = distribution_license_files(distribution)
        if not files:
            raise RuntimeError(
                f"Installed Python distribution {name} {distribution.version} exposes no installed license/notice file"
            )
        license_label = expression or (raw_license if 0 < len(raw_license) <= 160 else "See verbatim notice below")
        lines = [f"## Python distribution: {name} {distribution.version}", "", f"License metadata: {license_label}"]
        url = project_url(distribution)
        if url:
            lines.append(f"Upstream: {url}")
        for relative, text in files:
            lines.extend(["", f"### Verbatim installed file: {relative}", "", text])
        yield "\n".join(lines)


def installed_npm_package_directories(node_modules: Path) -> dict[str, Path]:
    """Return actual npm package roots without treating package fixtures as packages."""

    installed: dict[str, Path] = {}
    pending = [node_modules]
    visited: set[Path] = set()
    while pending:
        current = pending.pop()
        resolved = current.resolve(strict=True)
        if resolved in visited:
            raise RuntimeError(f"npm node_modules tree contains a directory cycle: {current}")
        visited.add(resolved)
        if current.is_symlink() or not current.is_dir():
            raise RuntimeError(f"npm node_modules directory is absent or linked: {current}")
        for child in sorted(current.iterdir()):
            if child.name == ".bin" or child.name.startswith("."):
                continue
            if child.name.startswith("@"):
                if child.is_symlink() or not child.is_dir():
                    raise RuntimeError(f"Installed npm scope root is linked or invalid: {child}")
                candidates = sorted(child.iterdir())
            else:
                candidates = [child]
            for package_dir in candidates:
                if package_dir.is_symlink() or not package_dir.is_dir():
                    raise RuntimeError(f"Installed npm package root is linked or invalid: {package_dir}")
                package_json = package_dir / "package.json"
                if not package_json.is_file() or package_json.is_symlink():
                    raise RuntimeError(f"Installed npm package lacks regular package.json: {package_dir}")
                relative = package_dir.relative_to(node_modules.parent).as_posix()
                if relative in installed:
                    raise RuntimeError(f"Duplicate installed npm package path: {relative}")
                installed[relative] = package_dir
                nested = package_dir / "node_modules"
                if nested.is_symlink():
                    raise RuntimeError(f"Installed npm package has a linked nested node_modules: {package_dir}")
                if nested.exists():
                    pending.append(nested)
    return installed


def frontend_sections(repo: Path) -> Iterable[str]:
    frontend = repo / "frontend"
    lock = json.loads((frontend / "package-lock.json").read_text(encoding="utf-8"))
    if int(lock.get("lockfileVersion", 0)) < 3:
        raise RuntimeError("npm lockfileVersion 3 or newer is required")
    locked_packages = {
        relative: value
        for relative, value in lock.get("packages", {}).items()
        if relative and "node_modules/" in relative
    }
    node_modules = frontend / "node_modules"
    installed_packages = installed_npm_package_directories(node_modules)
    unexpected = sorted(set(installed_packages) - set(locked_packages))
    if unexpected:
        raise RuntimeError(f"Installed npm package is absent from package-lock.json: {unexpected[0]}")
    missing_required = sorted(
        relative
        for relative, value in locked_packages.items()
        if not bool(value.get("optional")) and relative not in installed_packages
    )
    if missing_required:
        raise RuntimeError(f"Required locked npm package is not installed: {missing_required[0]}")
    if not installed_packages:
        raise RuntimeError("No installed locked npm packages were found")

    seen: set[tuple[str, str]] = set()
    for relative, package_dir in sorted(installed_packages.items()):
        locked = locked_packages[relative]
        package_json = require_regular_file(package_dir / "package.json", "npm package metadata")
        package = json.loads(package_json.read_text(encoding="utf-8"))
        name = str(package.get("name") or relative.rsplit("node_modules/", 1)[-1])
        version = str(locked.get("version") or package.get("version") or "")
        if not version or str(package.get("version")) != version or not locked.get("integrity"):
            raise RuntimeError(f"npm package {name} lacks exact installed version/integrity binding")
        key = (name, version)
        if key in seen:
            continue
        seen.add(key)
        license_label = str(package.get("license") or locked.get("license") or "").strip()
        files = sorted(
            require_regular_file(path, f"npm package {name} license source")
            for path in package_dir.iterdir()
            if path.is_file() and LICENSE_FILE.match(path.name)
        )
        if not license_label and not files:
            raise RuntimeError(f"Installed npm package {name} {version} exposes no license source")
        lines = [
            f"## Frontend distribution: {name} {version}",
            "",
            f"Lock integrity: `{locked['integrity']}`",
            f"License metadata: {license_label or 'See verbatim notice below'}",
        ]
        for path in files:
            lines.extend(["", f"### Verbatim installed file: {path.name}", "", read_text(path)])
        yield "\n".join(lines)


def dotnet_sections(repo: Path, publish: Path) -> Iterable[str]:
    project_file = repo / "desktop" / "StatFlow.Workbench.Desktop" / "StatFlow.Workbench.Desktop.csproj"
    project = ET.parse(project_file)
    runtime_versions = project.findall(".//RuntimeFrameworkVersion")
    if runtime_versions:
        raise RuntimeError(
            "Desktop project must not override every framework reference with RuntimeFrameworkVersion"
        )
    latest_runtime_patch = {
        str(node.text or "").strip().lower()
        for node in project.findall(".//TargetLatestRuntimePatch")
    }
    if latest_runtime_patch != {"true"}:
        raise RuntimeError("Desktop project must select the latest patch from the exact pinned SDK")
    webview_versions = {
        str(item.get("Version") or "").strip().strip("[]")
        for item in project.findall(".//PackageReference")
        if item.get("Include") == "Microsoft.Web.WebView2"
    }
    if webview_versions != {EXPECTED_WEBVIEW2}:
        raise RuntimeError("Desktop project does not pin exact Microsoft.Web.WebView2 1.0.4129.50")
    global_json = json.loads((repo / "global.json").read_text(encoding="utf-8"))
    if global_json.get("sdk") != {
        "version": EXPECTED_DOTNET_SDK,
        "rollForward": "disable",
        "allowPrerelease": False,
    }:
        raise RuntimeError("global.json must pin exact .NET SDK 8.0.424 with roll-forward disabled")
    actual_sdk = subprocess.run(
        ["dotnet", "--version"],
        check=True,
        capture_output=True,
        text=True,
        timeout=60,
    ).stdout.strip()
    if actual_sdk != EXPECTED_DOTNET_SDK:
        raise RuntimeError(f"Actual dotnet SDK is {actual_sdk!r}, expected exact {EXPECTED_DOTNET_SDK}")
    lock = json.loads((project_file.parent / "packages.lock.json").read_text(encoding="utf-8"))
    webview_lock = locked_webview_entry(lock)

    deps_files = list(publish.glob("StatFlow.Workbench.Desktop.deps.json"))
    runtime_files = list(publish.glob("StatFlow.Workbench.Desktop.runtimeconfig.json"))
    if len(deps_files) != 1 or len(runtime_files) != 1:
        raise RuntimeError("Final publish output lacks one exact desktop deps/runtimeconfig pair")
    deps = json.loads(deps_files[0].read_text(encoding="utf-8"))
    libraries = set(deps.get("libraries", {}))
    required_libraries = {
        f"runtimepack.Microsoft.NETCore.App.Runtime.win-x64/{EXPECTED_DOTNET_RUNTIME}",
        f"runtimepack.Microsoft.WindowsDesktop.App.Runtime.win-x64/{EXPECTED_DOTNET_RUNTIME}",
        f"Microsoft.Web.WebView2/{EXPECTED_WEBVIEW2}",
    }
    if not required_libraries.issubset(libraries):
        raise RuntimeError("Final deps.json does not bind exact .NET runtime packs and WebView2 package")
    runtime_config = json.loads(runtime_files[0].read_text(encoding="utf-8"))
    runtime_options = runtime_config.get("runtimeOptions", {})
    frameworks = runtime_options.get("includedFrameworks") or runtime_options.get("frameworks") or []
    if runtime_options.get("framework"):
        frameworks = [runtime_options["framework"], *frameworks]
    exact_frameworks = {(str(item.get("name")), str(item.get("version"))) for item in frameworks}
    if not {
        ("Microsoft.NETCore.App", EXPECTED_DOTNET_RUNTIME),
        ("Microsoft.WindowsDesktop.App", EXPECTED_DOTNET_RUNTIME),
    }.issubset(exact_frameworks):
        raise RuntimeError("Final runtimeconfig.json does not bind exact .NET 8.0.30 frameworks")

    dotnet_command = shutil.which("dotnet")
    if not dotnet_command:
        raise RuntimeError("The exact dotnet executable is unavailable")
    dotnet_executable = require_regular_file(Path(dotnet_command), "dotnet executable")
    discovered_dotnet_root = dotnet_executable.parent.resolve(strict=True)
    dotnet_root_text = os.environ.get("DOTNET_ROOT", "").strip()
    if dotnet_root_text:
        configured_dotnet_root = Path(dotnet_root_text).resolve(strict=True)
        if configured_dotnet_root != discovered_dotnet_root:
            raise RuntimeError("DOTNET_ROOT differs from the exact dotnet executable used for the build")
    dotnet_root = discovered_dotnet_root
    sdk_root = dotnet_root / "sdk" / EXPECTED_DOTNET_SDK
    if not sdk_root.is_dir() or sdk_root.is_symlink():
        raise RuntimeError(f"Exact .NET SDK directory is missing or linked: {sdk_root}")
    dotnet_license = require_regular_file(dotnet_root / "LICENSE.txt", ".NET SDK license")
    dotnet_notices = require_regular_file(dotnet_root / "ThirdPartyNotices.txt", ".NET SDK third-party notices")
    runtime_assets: list[Path] = []
    for name in ("coreclr.dll", "hostfxr.dll"):
        matches = [path for path in publish.rglob(name) if path.is_file() and not path.is_symlink()]
        if len(matches) != 1:
            raise RuntimeError(f"Expected one final {name}; found {len(matches)}")
        runtime_assets.extend(matches)
    nuget_root = Path(
        os.environ.get("NUGET_PACKAGES", Path.home() / ".nuget" / "packages")
    ).resolve(strict=True)
    runtime_notice_sources: list[Path] = []
    for package_name in (
        "microsoft.netcore.app.runtime.win-x64",
        "microsoft.windowsdesktop.app.runtime.win-x64",
    ):
        package_root = nuget_root / package_name / EXPECTED_DOTNET_RUNTIME
        if not package_root.is_dir() or package_root.is_symlink():
            raise RuntimeError(f"Exact .NET runtime pack is missing: {package_root}")
        notices = sorted(
            require_regular_file(path, f".NET runtime pack {package_name} notice source")
            for path in package_root.iterdir()
            if path.is_file() and LICENSE_FILE.match(path.name)
        )
        if not notices:
            raise RuntimeError(f"Exact .NET runtime pack exposes no license/notice source: {package_root}")
        runtime_notice_sources.extend(notices)
    lines = [
        f"## Microsoft .NET runtime {EXPECTED_DOTNET_RUNTIME} (win-x64, self-contained)",
        "",
        f"License source: exact .NET SDK {EXPECTED_DOTNET_SDK}, exact runtime-pack {EXPECTED_DOTNET_RUNTIME}, and the Microsoft notices below.",
    ]
    for asset in runtime_assets:
        lines.append(f"Final asset `{asset.relative_to(publish).as_posix()}` SHA-256: `{sha256(asset)}`")
    for source in (dotnet_license, dotnet_notices):
        lines.extend(["", f"### Verbatim .NET source: {source.name}", f"Source SHA-256: `{sha256(source)}`", "", read_text(source)])
    for source in runtime_notice_sources:
        lines.extend(
            [
                "",
                f"### Verbatim exact runtime-pack source: {source.relative_to(nuget_root).as_posix()}",
                f"Source SHA-256: `{sha256(source)}`",
                "",
                read_text(source),
            ]
        )
    yield "\n".join(lines)

    webview_root = nuget_root / "microsoft.web.webview2" / EXPECTED_WEBVIEW2
    if not webview_root.is_dir() or webview_root.is_symlink():
        raise RuntimeError(f"Exact WebView2 NuGet package is missing: {webview_root}")
    webview_nupkg_hash = require_regular_file(
        webview_root / f"microsoft.web.webview2.{EXPECTED_WEBVIEW2}.nupkg.sha512",
        "WebView2 raw NuGet package hash",
    )
    raw_webview_hash = read_text(webview_nupkg_hash)
    if not re.fullmatch(r"[A-Za-z0-9+/]{40,}={0,2}", raw_webview_hash):
        raise RuntimeError("Restored WebView2 raw NuGet package hash is malformed")
    assets_file = require_regular_file(
        project_file.parent / "obj" / "project.assets.json",
        "NuGet restore asset graph",
    )
    assets_graph = json.loads(assets_file.read_text(encoding="utf-8"))
    package_folders = {
        Path(path).resolve(strict=True) for path in assets_graph.get("packageFolders", {})
    }
    if package_folders != {nuget_root}:
        raise RuntimeError("NuGet asset graph does not bind the exact configured package root")
    webview_asset = assets_graph.get("libraries", {}).get(
        f"Microsoft.Web.WebView2/{EXPECTED_WEBVIEW2}", {}
    )
    if (
        webview_asset.get("type") != "package"
        or webview_asset.get("sha512") != webview_lock["contentHash"]
        or webview_asset.get("path") != f"microsoft.web.webview2/{EXPECTED_WEBVIEW2}"
    ):
        raise RuntimeError("NuGet asset graph differs from the locked WebView2 package")
    webview_license_files = sorted(
        require_regular_file(path, "WebView2 license/notice source")
        for path in webview_root.rglob("*")
        if path.is_file() and LICENSE_FILE.match(path.name)
    )
    if not webview_license_files:
        raise RuntimeError("Exact WebView2 NuGet package exposes no license/notice file")
    webview_assets: list[Path] = []
    for name in ("Microsoft.Web.WebView2.Core.dll", "WebView2Loader.dll"):
        matches = [path for path in publish.rglob(name) if path.is_file() and not path.is_symlink()]
        if not matches:
            raise RuntimeError(f"Final publish output lacks WebView2 asset {name}")
        webview_assets.extend(matches)
    lines = [
        f"## Microsoft Edge WebView2 SDK {EXPECTED_WEBVIEW2}",
        "",
        "The SDK/loader assemblies are redistributed; Evergreen Runtime remains an external dependency.",
        f"Raw restored package SHA-512: `{raw_webview_hash}`",
    ]
    for asset in sorted(set(webview_assets)):
        lines.append(f"Final asset `{asset.relative_to(publish).as_posix()}` SHA-256: `{sha256(asset)}`")
    for source in webview_license_files:
        lines.extend(["", f"### Verbatim WebView2 package file: {source.relative_to(webview_root).as_posix()}", f"Source SHA-256: `{sha256(source)}`", "", read_text(source)])
    yield "\n".join(lines)


def publish_inventory_section(publish: Path, output: Path) -> str:
    output_resolved = output.resolve(strict=False)
    files: list[Path] = []
    for path in publish.rglob("*"):
        if path.is_symlink():
            raise RuntimeError(f"Final Windows publish tree contains a symbolic link: {path}")
        if path.is_file() and path.resolve() != output_resolved:
            files.append(path)
    if not files or len(files) > 50_000:
        raise RuntimeError(f"Final Windows publish inventory count is unsafe: {len(files)}")
    lines = [
        "## Exact final publish asset inventory before this generated notice is injected",
        "",
        f"Asset count: {len(files)}",
        "",
    ]
    for path in sorted(files, key=lambda value: value.relative_to(publish).as_posix().casefold()):
        lines.append(f"`{sha256(path)}`  `{path.relative_to(publish).as_posix()}`")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate fail-closed notices from exact candidate assets")
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--publish-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repo = args.repo.resolve(strict=True)
    publish = args.publish_directory.resolve(strict=True)
    output = args.output.resolve(strict=False)
    try:
        output.relative_to(publish)
    except ValueError as error:
        raise RuntimeError("Generated third-party notices must be written inside the exact publish tree") from error
    preamble = """# Survey Data Workbench by LAI ZEYU — Third-Party Notices

Generated fail-closed from the exact Python 3.12 environment, installed npm and
NuGet packages, pinned .NET 8.0.30 runtime packs, and final Windows publish
assets. Developer / 开发者: LAI ZEYU（来泽宇）.

IBM SPSS Statistics, its Python integration, and its licence are not bundled."""
    sections = [
        preamble,
        python_runtime_section(publish),
        *python_sections(repo),
        *frontend_sections(repo),
        *dotnet_sections(repo, publish),
        publish_inventory_section(publish, output),
    ]
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n\n---\n\n".join(sections).rstrip() + "\n", encoding="utf-8")
    if output.stat().st_size < 4096:
        raise RuntimeError("Generated third-party notices are unexpectedly incomplete")
    print(f"Generated exact candidate notices: {output} ({output.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
