from __future__ import annotations

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ATTRIBUTION = "LAI ZEYU（来泽宇）"
PRODUCT_NAME = "Survey Data Workbench by LAI ZEYU"


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def main() -> int:
    failures: list[str] = []
    required_occurrences = {
        "frontend/src/components/InfoDialog.jsx": 1,
        "desktop/StatFlow.Workbench.Desktop/StatFlow.Workbench.Desktop.csproj": 1,
        "packaging/AppxManifest.template.xml": 1,
        "frontend/package.json": 1,
        "scripts/Test-WindowsSidecar.ps1": 1,
        "store/LISTING.md": 3,
        "store/PRIVACY_POLICY.md": 1,
        "README.md": 2,
        "NOTICE.md": 2,
        "THIRD_PARTY_NOTICES.md": 1,
        "store/RELEASE_NOTES.md": 1,
        "LICENSE": 1,
        "CITATION.cff": 1,
    }
    for relative, minimum in required_occurrences.items():
        path = ROOT / relative
        if not path.is_file():
            failures.append(f"missing required attribution file: {relative}")
            continue
        count = read(relative).count(ATTRIBUTION)
        if count < minimum:
            failures.append(
                f"{relative}: expected at least {minimum} exact '{ATTRIBUTION}' attribution(s), found {count}"
            )

    try:
        package = json.loads(read("frontend/package.json"))
        if package.get("author") != ATTRIBUTION:
            failures.append("frontend/package.json: author metadata is not the exact bilingual attribution")
    except (OSError, json.JSONDecodeError) as error:
        failures.append(f"frontend/package.json: cannot parse package metadata: {error}")

    try:
        project = ET.parse(ROOT / "desktop/StatFlow.Workbench.Desktop/StatFlow.Workbench.Desktop.csproj")
        author = project.findtext(".//Authors")
        company = project.findtext(".//Company")
        if author != ATTRIBUTION or company != ATTRIBUTION:
            failures.append("desktop csproj: Authors and Company must both use the exact bilingual attribution")
    except (OSError, ET.ParseError) as error:
        failures.append(f"desktop csproj: cannot parse package metadata: {error}")

    try:
        manifest = ET.parse(ROOT / "packaging/AppxManifest.template.xml")
        namespace = {"f": "http://schemas.microsoft.com/appx/manifest/foundation/windows10"}
        publisher = manifest.findtext("f:Properties/f:PublisherDisplayName", namespaces=namespace)
        display_name = manifest.findtext("f:Properties/f:DisplayName", namespaces=namespace)
        description = manifest.findtext("f:Properties/f:Description", namespaces=namespace) or ""
        if publisher != "__PUBLISHER_DISPLAY_NAME__":
            failures.append(
                "AppxManifest: PublisherDisplayName must remain a Partner Center identity placeholder"
            )
        if display_name != PRODUCT_NAME:
            failures.append("AppxManifest: the approved main product name changed")
        if ATTRIBUTION not in description:
            failures.append("AppxManifest: product description is missing exact bilingual authorship")
    except (OSError, ET.ParseError) as error:
        failures.append(f"AppxManifest: cannot parse package metadata: {error}")

    listing = read("store/LISTING.md") if (ROOT / "store/LISTING.md").is_file() else ""
    if "## English listing" not in listing or "## 中文商店文案" not in listing:
        failures.append("store/LISTING.md: both English and Chinese listing sections are required")
    else:
        english_listing, chinese_listing = listing.split("## 中文商店文案", 1)
        if f"Author: **{ATTRIBUTION}**" not in english_listing:
            failures.append("store/LISTING.md: English listing is missing the exact bilingual author")
        if f"开发者：**{ATTRIBUTION}**" not in chinese_listing:
            failures.append("store/LISTING.md: Chinese listing is missing the exact bilingual author")

    required_snippets = {
        "README.md": f"Author / 开发者: **{ATTRIBUTION}**.",
        "NOTICE.md": f"published by **{ATTRIBUTION}**.",
        "store/RELEASE_NOTES.md": f"Developer / 开发者: **{ATTRIBUTION}**",
        "store/PRIVACY_POLICY.md": f"Developer / 开发者: **{ATTRIBUTION}**.",
    }
    for relative, snippet in required_snippets.items():
        if (ROOT / relative).is_file() and snippet not in read(relative):
            failures.append(f"{relative}: explicit exact bilingual authorship line is required")

    about = read("frontend/src/components/InfoDialog.jsx") if (ROOT / "frontend/src/components/InfoDialog.jsx").is_file() else ""
    if f"<strong>{ATTRIBUTION}</strong> 独立开发" not in about:
        failures.append("InfoDialog About: explicit independent bilingual authorship is required")

    if failures:
        print("Attribution gate failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    # Keep the success line ASCII-only because Windows hosted runners can expose
    # a legacy cp1252 stdout even though the repository files are UTF-8. The
    # checks above still require the exact bilingual attribution in every file.
    print("Attribution gate passed for LAI ZEYU and the required Chinese author form.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
