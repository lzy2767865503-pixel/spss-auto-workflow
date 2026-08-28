from __future__ import annotations

import base64
import hashlib
import hmac
import importlib.util
import json
import unittest
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "verify_spss_release_attestations",
    ROOT / "scripts" / "verify_spss_release_attestations.py",
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ProtectedPrivateAssertionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tag = "windows-v1.1.0"
        self.commit = "a" * 40
        self.context = MODULE.release_context(ROOT, self.tag, self.commit, "1.1.0")
        self.key = bytes(range(32))
        self.key_base64 = base64.b64encode(self.key).decode("ascii")
        self.candidate_hash = hashlib.sha256(b"same-private-windows-layout-manifest").hexdigest()

    def make_record(self, suffix: str, *, build: str) -> str:
        comparisons = {
            name: {"comparedValues": 3, "tolerance": 0.000001, "maxAbsDelta": 0.0}
            for name in MODULE.REQUIRED_COMPARISONS
        }
        value = {
            "schemaVersion": 1,
            "assertionId": f"assertion-{suffix}",
            "releaseTag": self.tag,
            "sourceCommit": self.commit,
            "applicationVersion": "1.1.0",
            "scope": "source-commit-and-integration-contract",
            "testedCandidate": {
                "kind": "private-windows-layout-manifest",
                "sha256": self.candidate_hash,
            },
            "environmentId": f"environment-{suffix}",
            "windows": {
                "edition": "Windows 11 Pro",
                "version": "24H2",
                "build": build,
                "architecture": "x64",
            },
            "spss": {
                "version": "29.0.2",
                "pythonIntegrationVersion": "29.0.2-python3",
                "licenseAuthorized": True,
            },
            "fixture": {
                "path": "examples/synthetic_survey.csv",
                "sha256": self.context["fixtureSha256"],
            },
            "integration": {
                "contractVersion": self.context["integrationContractVersion"],
                "sourceSha256": self.context["integrationSourceSha256"],
            },
            "execution": {
                "testedAtUtc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "applicationRestartRepeated": True,
                "formalRunState": "complete",
                "formatIntegrityVerified": True,
                "manualSyntaxComparisonPassed": True,
                "semanticComparisonPassed": True,
            },
            "comparisons": comparisons,
            "privateEvidenceSha256": hashlib.sha256(f"private-{suffix}".encode()).hexdigest(),
        }
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

    def sign(self, raw: str) -> str:
        return hmac.new(self.key, raw.encode("utf-8"), hashlib.sha256).hexdigest()

    def test_two_reviewer_approved_hmac_integrity_records_return_candidate(self) -> None:
        first = self.make_record("one", build="26100.1000")
        second = self.make_record("two", build="26100.2000")
        candidate = MODULE.verify_pair(
            first,
            self.sign(first),
            second,
            self.sign(second),
            self.key_base64,
            self.context,
        )
        self.assertEqual(candidate, self.candidate_hash)

    def test_tampering_after_hmac_is_rejected(self) -> None:
        first = self.make_record("one", build="26100.1000")
        second = self.make_record("two", build="26100.2000")
        with self.assertRaisesRegex(MODULE.PrivateAssertionError, "HMAC verification failed"):
            MODULE.verify_pair(
                first.replace('"formalRunState":"complete"', '"formalRunState":"failed"'),
                self.sign(first),
                second,
                self.sign(second),
                self.key_base64,
                self.context,
            )

    def test_record_cannot_claim_exact_signed_package_scope(self) -> None:
        first = self.make_record("one", build="26100.1000").replace(
            "source-commit-and-integration-contract", "exact-signed-msix"
        )
        second = self.make_record("two", build="26100.2000")
        with self.assertRaisesRegex(MODULE.PrivateAssertionError, "must not claim"):
            MODULE.verify_pair(
                first,
                self.sign(first),
                second,
                self.sign(second),
                self.key_base64,
                self.context,
            )

    def test_two_environments_must_bind_the_same_private_layout_manifest(self) -> None:
        first = self.make_record("one", build="26100.1000")
        second = self.make_record("two", build="26100.2000").replace(
            self.candidate_hash,
            hashlib.sha256(b"different-private-layout").hexdigest(),
        )
        with self.assertRaisesRegex(MODULE.PrivateAssertionError, "same private Windows layout"):
            MODULE.verify_pair(
                first,
                self.sign(first),
                second,
                self.sign(second),
                self.key_base64,
                self.context,
            )


if __name__ == "__main__":
    unittest.main()
