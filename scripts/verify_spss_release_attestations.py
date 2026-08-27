#!/usr/bin/env python3
"""Verify two reviewer-approved private IBM SPSS assertions.

The shared HMAC detects accidental or out-of-band record changes inside one
protected GitHub environment. It is not an independent signature, does not
establish two cryptographic identities, and does not prove the self-declared
environment facts. Human environment approval remains the trust boundary.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import hmac
import json
import math
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


CONTRACT_VERSION = "statflow-spss-integration-v1"
INTEGRATION_FILES = (
    "backend/analysis_engine.py",
    "backend/spss_runner/base.py",
    "backend/spss_runner/windows.py",
)
REQUIRED_COMPARISONS = (
    "descriptives",
    "reliability",
    "correlations",
    "factorability",
    "regression",
)
HEX_64 = re.compile(r"^[0-9a-f]{64}$")
HEX_40 = re.compile(r"^[0-9a-f]{40}$")
SAFE_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$")


class PrivateAssertionError(ValueError):
    pass


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise PrivateAssertionError(f"duplicate JSON property: {key}")
        value[key] = item
    return value


def _exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise PrivateAssertionError(f"{label} properties differ; missing={missing}, extra={extra}")


def _safe_text(value: Any, label: str, *, max_length: int = 256) -> str:
    if not isinstance(value, str) or not value or len(value) > max_length:
        raise PrivateAssertionError(f"{label} must be a non-empty string of at most {max_length} characters")
    if any(ord(character) < 0x20 for character in value):
        raise PrivateAssertionError(f"{label} contains a control character")
    return value


def integration_source_sha256(repo: Path) -> str:
    digest = hashlib.sha256()
    for relative in INTEGRATION_FILES:
        source = repo / relative
        data = source.read_bytes()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(hashlib.sha256(data).digest())
    return digest.hexdigest()


def release_context(repo: Path, tag: str, commit: str, app_version: str) -> dict[str, str]:
    fixture = repo / "examples/synthetic_survey.csv"
    return {
        "releaseTag": tag,
        "sourceCommit": commit,
        "applicationVersion": app_version,
        "fixtureSha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
        "integrationContractVersion": CONTRACT_VERSION,
        "integrationSourceSha256": integration_source_sha256(repo),
    }


def _decode_hmac_key(encoded: str) -> bytes:
    try:
        key = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as error:
        raise PrivateAssertionError("private-assertion HMAC key is not strict base64") from error
    if len(key) < 32:
        raise PrivateAssertionError("private-assertion HMAC key must contain at least 256 bits")
    return key


def _parse_assertion(raw: str, signature: str, key: bytes, label: str) -> dict[str, Any]:
    if len(raw.encode("utf-8")) > 64 * 1024:
        raise PrivateAssertionError(f"{label} exceeds the 64 KiB protected-record limit")
    if not HEX_64.fullmatch(signature):
        raise PrivateAssertionError(f"{label} HMAC must be 64 lowercase hexadecimal characters")
    expected = hmac.new(key, raw.encode("utf-8"), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, signature):
        raise PrivateAssertionError(f"{label} HMAC verification failed")
    try:
        value = json.loads(raw, object_pairs_hook=_reject_duplicate_keys)
    except (json.JSONDecodeError, PrivateAssertionError) as error:
        raise PrivateAssertionError(f"{label} is not strict duplicate-free JSON: {error}") from error
    if not isinstance(value, dict):
        raise PrivateAssertionError(f"{label} must be one JSON object")
    return value


def _validate_one(value: dict[str, Any], context: dict[str, str], label: str) -> dict[str, str]:
    _exact_keys(
        value,
        {
            "schemaVersion",
            "assertionId",
            "releaseTag",
            "sourceCommit",
            "applicationVersion",
            "scope",
            "testedCandidate",
            "environmentId",
            "windows",
            "spss",
            "fixture",
            "integration",
            "execution",
            "comparisons",
            "privateEvidenceSha256",
        },
        label,
    )
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        raise PrivateAssertionError(f"{label}.schemaVersion must be integer 1")
    assertion_id = _safe_text(value["assertionId"], f"{label}.assertionId", max_length=128)
    environment_id = _safe_text(value["environmentId"], f"{label}.environmentId", max_length=128)
    if not SAFE_IDENTIFIER.fullmatch(assertion_id) or not SAFE_IDENTIFIER.fullmatch(environment_id):
        raise PrivateAssertionError(f"{label} identifiers must be pseudonymous safe identifiers")
    for field in ("releaseTag", "sourceCommit", "applicationVersion"):
        if value[field] != context[field]:
            raise PrivateAssertionError(f"{label}.{field} does not bind to the selected release")
    if not HEX_40.fullmatch(value["sourceCommit"]):
        raise PrivateAssertionError(f"{label}.sourceCommit must be a lowercase 40-character commit ID")
    if value["scope"] != "source-commit-and-integration-contract":
        raise PrivateAssertionError(
            f"{label}.scope must not claim validation of a later signed installer or Store MSIX"
        )

    tested_candidate = value["testedCandidate"]
    if not isinstance(tested_candidate, dict):
        raise PrivateAssertionError(f"{label}.testedCandidate must be an object")
    _exact_keys(tested_candidate, {"kind", "sha256"}, f"{label}.testedCandidate")
    if tested_candidate["kind"] != "private-windows-layout-manifest":
        raise PrivateAssertionError(
            f"{label}.testedCandidate.kind must identify the private Windows layout manifest"
        )
    candidate_hash = tested_candidate["sha256"]
    if not isinstance(candidate_hash, str) or not HEX_64.fullmatch(candidate_hash):
        raise PrivateAssertionError(f"{label}.testedCandidate.sha256 must be a lowercase SHA-256 digest")

    windows = value["windows"]
    if not isinstance(windows, dict):
        raise PrivateAssertionError(f"{label}.windows must be an object")
    _exact_keys(windows, {"edition", "version", "build", "architecture"}, f"{label}.windows")
    for field in ("edition", "version", "build"):
        _safe_text(windows[field], f"{label}.windows.{field}")
    if windows["architecture"] != "x64":
        raise PrivateAssertionError(f"{label}.windows.architecture must be x64")

    spss = value["spss"]
    if not isinstance(spss, dict):
        raise PrivateAssertionError(f"{label}.spss must be an object")
    _exact_keys(spss, {"version", "pythonIntegrationVersion", "licenseAuthorized"}, f"{label}.spss")
    _safe_text(spss["version"], f"{label}.spss.version")
    _safe_text(spss["pythonIntegrationVersion"], f"{label}.spss.pythonIntegrationVersion")
    if spss["licenseAuthorized"] is not True:
        raise PrivateAssertionError(f"{label} must confirm an authorised IBM SPSS licence without exposing it")

    fixture = value["fixture"]
    if not isinstance(fixture, dict):
        raise PrivateAssertionError(f"{label}.fixture must be an object")
    _exact_keys(fixture, {"path", "sha256"}, f"{label}.fixture")
    if fixture["path"] != "examples/synthetic_survey.csv" or fixture["sha256"] != context["fixtureSha256"]:
        raise PrivateAssertionError(f"{label}.fixture is not the committed release fixture")

    integration = value["integration"]
    if not isinstance(integration, dict):
        raise PrivateAssertionError(f"{label}.integration must be an object")
    _exact_keys(integration, {"contractVersion", "sourceSha256"}, f"{label}.integration")
    if integration["contractVersion"] != context["integrationContractVersion"]:
        raise PrivateAssertionError(f"{label} integration contract version differs")
    if integration["sourceSha256"] != context["integrationSourceSha256"]:
        raise PrivateAssertionError(f"{label} integration source digest differs")

    execution = value["execution"]
    if not isinstance(execution, dict):
        raise PrivateAssertionError(f"{label}.execution must be an object")
    _exact_keys(
        execution,
        {
            "testedAtUtc",
            "applicationRestartRepeated",
            "formalRunState",
            "formatIntegrityVerified",
            "manualSyntaxComparisonPassed",
            "semanticComparisonPassed",
        },
        f"{label}.execution",
    )
    for field in (
        "applicationRestartRepeated",
        "formatIntegrityVerified",
        "manualSyntaxComparisonPassed",
        "semanticComparisonPassed",
    ):
        if execution[field] is not True:
            raise PrivateAssertionError(f"{label}.execution.{field} must be true")
    if execution["formalRunState"] != "complete":
        raise PrivateAssertionError(f"{label}.execution.formalRunState must be complete")
    tested_text = _safe_text(execution["testedAtUtc"], f"{label}.execution.testedAtUtc")
    try:
        tested = datetime.fromisoformat(tested_text.replace("Z", "+00:00"))
    except ValueError as error:
        raise PrivateAssertionError(f"{label}.execution.testedAtUtc is not ISO-8601") from error
    if tested.tzinfo is None or tested.utcoffset() != timedelta(0):
        raise PrivateAssertionError(f"{label}.execution.testedAtUtc must be UTC")
    now = datetime.now(timezone.utc)
    if tested > now + timedelta(minutes=10) or tested < now - timedelta(days=180):
        raise PrivateAssertionError(f"{label}.execution.testedAtUtc is future-dated or older than 180 days")

    comparisons = value["comparisons"]
    if not isinstance(comparisons, dict):
        raise PrivateAssertionError(f"{label}.comparisons must be an object")
    _exact_keys(comparisons, set(REQUIRED_COMPARISONS), f"{label}.comparisons")
    for category in REQUIRED_COMPARISONS:
        comparison = comparisons[category]
        if not isinstance(comparison, dict):
            raise PrivateAssertionError(f"{label}.comparisons.{category} must be an object")
        _exact_keys(comparison, {"comparedValues", "tolerance", "maxAbsDelta"}, f"{label}.comparisons.{category}")
        count = comparison["comparedValues"]
        tolerance = comparison["tolerance"]
        delta = comparison["maxAbsDelta"]
        if type(count) is not int or count < 1 or count > 1_000_000:
            raise PrivateAssertionError(f"{label}.comparisons.{category}.comparedValues is invalid")
        if isinstance(tolerance, bool) or not isinstance(tolerance, (int, float)):
            raise PrivateAssertionError(f"{label}.comparisons.{category}.tolerance must be numeric")
        if isinstance(delta, bool) or not isinstance(delta, (int, float)):
            raise PrivateAssertionError(f"{label}.comparisons.{category}.maxAbsDelta must be numeric")
        if not math.isfinite(float(tolerance)) or not (0 < float(tolerance) <= 1e-4):
            raise PrivateAssertionError(f"{label}.comparisons.{category}.tolerance exceeds the 1e-4 gate")
        if not math.isfinite(float(delta)) or float(delta) < 0 or float(delta) > float(tolerance):
            raise PrivateAssertionError(f"{label}.comparisons.{category} exceeds its stated tolerance")

    evidence_hash = value["privateEvidenceSha256"]
    if not isinstance(evidence_hash, str) or not HEX_64.fullmatch(evidence_hash):
        raise PrivateAssertionError(f"{label}.privateEvidenceSha256 must be a lowercase SHA-256 digest")
    if evidence_hash == candidate_hash:
        raise PrivateAssertionError(f"{label} private evidence and candidate manifest hashes must differ")
    return {
        "assertionId": assertion_id,
        "environmentId": environment_id,
        "privateEvidenceSha256": evidence_hash,
        "testedCandidateSha256": candidate_hash,
        "windowsFingerprint": "|".join(str(windows[field]) for field in ("edition", "version", "build", "architecture")),
    }


def verify_pair(
    raw_one: str,
    signature_one: str,
    raw_two: str,
    signature_two: str,
    key_base64: str,
    context: dict[str, str],
) -> str:
    key = _decode_hmac_key(key_base64)
    first = _validate_one(_parse_assertion(raw_one, signature_one, key, "private assertion 1"), context, "private assertion 1")
    second = _validate_one(_parse_assertion(raw_two, signature_two, key, "private assertion 2"), context, "private assertion 2")
    for field in ("assertionId", "environmentId", "privateEvidenceSha256", "windowsFingerprint"):
        if first[field] == second[field]:
            raise PrivateAssertionError(f"the two reviewer-approved assertions must have distinct {field} values")
    if first["testedCandidateSha256"] != second["testedCandidateSha256"]:
        raise PrivateAssertionError("the two claimed licensed environments must reference the same private Windows layout manifest")
    return first["testedCandidateSha256"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--app-version", required=True)
    parser.add_argument("--print-context", action="store_true")
    parser.add_argument("--print-candidate-sha256-only", action="store_true")
    args = parser.parse_args()
    repo = args.repo.resolve()
    context = release_context(repo, args.tag, args.commit, args.app_version)
    if args.print_context:
        print(json.dumps(context, sort_keys=True, separators=(",", ":")))
        return 0
    required = (
        "SPSS_ASSERTION_1_JSON",
        "SPSS_ASSERTION_1_HMAC_SHA256",
        "SPSS_ASSERTION_2_JSON",
        "SPSS_ASSERTION_2_HMAC_SHA256",
        "SPSS_ASSERTION_HMAC_KEY_BASE64",
    )
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise PrivateAssertionError("missing reviewer-approved private assertion inputs: " + ", ".join(missing))
    candidate_sha256 = verify_pair(
        os.environ["SPSS_ASSERTION_1_JSON"],
        os.environ["SPSS_ASSERTION_1_HMAC_SHA256"],
        os.environ["SPSS_ASSERTION_2_JSON"],
        os.environ["SPSS_ASSERTION_2_HMAC_SHA256"],
        os.environ["SPSS_ASSERTION_HMAC_KEY_BASE64"],
        context,
    )
    if args.print_candidate_sha256_only:
        print(candidate_sha256)
    else:
        print("Two reviewer-approved private IBM SPSS assertions match the selected source commit and integration contract; shared HMAC is integrity-only, not independent proof.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (PrivateAssertionError, OSError) as error:
        print(f"SPSS private-assertion gate failed: {error}", file=sys.stderr)
        raise SystemExit(1)
