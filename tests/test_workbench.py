from __future__ import annotations

import ast
import importlib.util
import os
import sys
import json
import re
import shutil
import subprocess
import tempfile
import threading
import time
import types
import unittest
import zipfile
from datetime import timedelta
from io import BytesIO, StringIO
from pathlib import Path
from unittest.mock import patch

import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "backend"
FIXTURE = ROOT / "examples" / "synthetic_survey.csv"
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))

from analysis_engine import (  # noqa: E402
    MAX_DATASET_CELLS,
    MAX_DATASET_COLUMNS,
    MAX_DATASET_ROWS,
    PORTABLE_COMMAND_PATH_TOKEN,
    PORTABLE_STATUS_LITERAL_TOKEN,
    _preflight_excel_archive,
    _validate_dataset_shape,
    build_portable_spss_template,
    cronbach_alpha,
    detect_constructs,
    execute_workflow,
    generate_spss_python_driver,
    inspect_dataset,
    make_bundle,
    normalize_dataset_columns,
    read_dataset,
    sanitize_spss_name,
)
from app import create_app, utc_now  # noqa: E402
from server import parent_is_alive, watch_parent  # noqa: E402
from spss_runner import public_spss_status  # noqa: E402
from spss_runner.base import EXPECTED_FORMAL_OUTPUTS, marker_result  # noqa: E402
from spss_runner.windows import (  # noqa: E402
    WindowsSpssRunner,
    build_cmd_invocation,
    detect_windows_spss,
    system_cmd_path,
    validate_cmd_path,
)


class AnalysisEngineTests(unittest.TestCase):
    def test_required_bilingual_attribution_gate(self) -> None:
        environment = os.environ.copy()
        environment["PYTHONIOENCODING"] = "cp1252"
        completed = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "check_attribution.py")],
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(completed.stdout.isascii(), completed.stdout)

    def test_windows_qa_reuses_one_hash_verified_candidate(self) -> None:
        build_workflow = (ROOT / ".github" / "workflows" / "windows-store.yml").read_text(
            encoding="utf-8"
        )
        review_workflow = (
            ROOT / ".github" / "workflows" / "windows-store-interactive.yml"
        ).read_text(encoding="utf-8")
        interactive_action = (
            ROOT / ".github" / "actions" / "run-windows-store-interactive" / "action.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("hosted-source-gates:", build_workflow)
        self.assertIn("stage-private-store-candidate:", build_workflow)
        self.assertNotIn("actions/upload-artifact", build_workflow)
        self.assertNotIn("actions/download-artifact", build_workflow)
        self.assertEqual(build_workflow.count("Build-Windows.ps1"), 1)
        self.assertEqual(build_workflow.count("Build-Msix.ps1"), 1)
        self.assertEqual(build_workflow.count("Test-WindowsSidecar.ps1"), 2)
        self.assertGreaterEqual(build_workflow.count("Verify-ArtifactHashes.ps1"), 4)
        self.assertIn("group: trusted-windows-store-build", build_workflow)
        self.assertIn("environment: trusted-windows-store-build", build_workflow)
        self.assertIn("private-acl-store-candidate", build_workflow)
        self.assertIn("candidateManifestSha256", build_workflow)
        self.assertIn("github.repository_id == '1311362169'", build_workflow)
        self.assertIn("github.ref == 'refs/heads/main'", build_workflow)
        self.assertIn("github.ref_protected == true", build_workflow)
        self.assertIn("without any GitHub artifact", build_workflow)
        self.assertEqual(build_workflow.count("publish-handoff"), 1)
        self.assertEqual(build_workflow.count("assert-handoff"), 1)
        self.assertEqual(build_workflow.count("--forbid-writer"), 2)
        self.assertIn("STORE_HANDOFF_OWNER_PRINCIPAL", build_workflow)
        self.assertIn("STORE_HANDOFF_CLEANUP_PRINCIPAL", build_workflow)
        immutable_store_handoff = build_workflow.split("publish-handoff", 1)[1].split(
            "} finally", 1
        )[0]
        self.assertNotIn("HANDOFF_BUILDER_PRINCIPAL):(OI)(CI)(F)", immutable_store_handoff)

        self.assertIn("workflow_run:", review_workflow)
        self.assertIn("compare/$($env:EVENT_HEAD_SHA)...main", review_workflow)
        self.assertIn("comparison.status -cne 'identical'", review_workflow)
        self.assertIn("trusted-windows-store-win10", review_workflow)
        self.assertIn("trusted-windows-store-win11", review_workflow)
        self.assertIn("group: trusted-windows-interactive-win10", review_workflow)
        self.assertIn("group: trusted-windows-interactive-win11", review_workflow)
        self.assertIn("group: trusted-windows-store-cleanup", review_workflow)
        self.assertIn("delete-handoff", review_workflow)
        store_cleanup = review_workflow.split("\n  cleanup-private-handoff:", 1)[1]
        self.assertNotIn("workflow_run.conclusion == 'success'", store_cleanup)
        self.assertIn("WINDOWS_APPCERT_SHA256", review_workflow)
        self.assertEqual(interactive_action.count("Test-MsixLifecycle.ps1"), 2)
        self.assertEqual(interactive_action.count("Prepare-MsixTestCandidate.ps1"), 1)
        self.assertEqual(interactive_action.count("Cleanup-MsixTestCandidate.ps1"), 1)
        self.assertIn("reviewWorkflowRunId", interactive_action)
        self.assertIn("github.workflow_sha", interactive_action)
        self.assertIn("approvedWackToolSha256", interactive_action)
        self.assertIn("assert-handoff", interactive_action)
        self.assertIn("--forbid-writer", interactive_action)
        self.assertIn("handoffHarnessSha256", interactive_action)

        def assert_store_handoff_policy(build: str, action: str, review: str) -> None:
            assert build.count("publish-handoff") == 1
            assert build.count("assert-handoff") == 1
            assert build.count("--forbid-writer") == 2
            assert action.count("assert-handoff") == 1
            assert action.count("--forbid-writer") == 1
            assert "trusted-windows-store-cleanup" in review
            assert "delete-handoff" in review

        assert_store_handoff_policy(build_workflow, interactive_action, review_workflow)
        with self.assertRaises(AssertionError):
            assert_store_handoff_policy(
                build_workflow.replace("--forbid-writer", "--allow-writer", 1),
                interactive_action,
                review_workflow,
            )
        publish_action = (
            ROOT / ".github" / "actions" / "publish-windows-gate-evidence" / "action.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("New-PublicWindowsGateEvidence.ps1", publish_action)
        self.assertIn("actions/upload-artifact", publish_action)
        self.assertIn("windows-gate-summary.v3.json", publish_action)
        self.assertIn("icacls.exe", publish_action)
        self.assertNotIn("path: artifacts/", publish_action)
        self.assertNotIn("path: test-results/", publish_action)
        self.assertNotIn(".xml", publish_action)
        lifecycle = (ROOT / "scripts" / "Test-MsixLifecycle.ps1").read_text(encoding="utf-8")
        self.assertNotIn("New-SelfSignedCertificate", lifecycle)
        self.assertIn("signedPackageSha256", lifecycle)
        self.assertIn("Package data already existed before the first launch", lifecycle)
        self.assertIn("A stale WACK report could not be removed", lifecycle)
        self.assertIn("Add-AppxPackage", lifecycle)
        self.assertIn("PackageActivator", lifecycle)
        self.assertIn("msedgewebview2.exe", lifecycle)
        self.assertIn("LocalState remained after MSIX uninstall", lifecycle)
        self.assertIn('Arguments @("reset")', lifecycle)
        self.assertIn('"-appxpackagepath", $signedPackage, "-reportoutputpath", $wackReport', lifecycle)
        self.assertIn("Invoke-BoundedNativeProcess", lifecycle)
        self.assertIn("active interactive Windows user session", lifecycle)
        self.assertIn('$overallResult -cne "PASS"', lifecycle)
        self.assertIn("PARTIAL_RUN", lifecycle)
        self.assertIn("LATEST_VERSION", lifecycle)
        self.assertIn("Assert-WackXmlPass", lifecycle)
        self.assertNotIn('Get-Command "appcert.exe"', lifecycle)
        self.assertIn("Get-TrustedWindowsAppCertificationKit", lifecycle)
        sdk_helper = (ROOT / "scripts" / "Trusted-WindowsSdkTool.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn('"Microsoft Corporation"', sdk_helper)
        self.assertIn("path contains a reparse point", sdk_helper)
        self.assertIn("versioned Windows SDK x64", sdk_helper)
        self.assertIn("wackToolSha256", lifecycle)
        self.assertIn("wackReportSha256", lifecycle)
        self.assertIn("ExpectedWackToolSha256", lifecycle)
        self.assertEqual(build_workflow.count("windows_release_policy.tests.ps1"), 2)
        self.assertIn("Refusing to alter a pre-existing package", lifecycle)
        self.assertNotIn("Wait-CiEvidence", lifecycle)
        self.assertNotIn("ci-installed-preview-evidence.json", lifecycle)
        self.assertIn("ExecutablePath", lifecycle)
        self.assertGreaterEqual(lifecycle.count("Assert-ExactInstalledManifest"), 3)
        self.assertIn('[string]$applications[0].Executable -cne "StatFlow.Workbench.Desktop.exe"', lifecycle)
        self.assertIn('[string]$manifest.Package.Identity.Version -cne "1.1.0.0"', lifecycle)
        self.assertIn("expectedDesktopExecutable", lifecycle)
        self.assertIn("expectedBackendExecutable", lifecycle)
        self.assertIn("CreationDate", lifecycle)
        self.assertIn("Assert-OwnedProcessIdentity -Record $DesktopRecord", lifecycle)
        self.assertIn("Assert-OwnedProcessIdentity -Record $BackendRecord", lifecycle)
        self.assertIn('$listeners.Count -eq 1', lifecycle)
        self.assertIn('$listeners[0].LocalAddress -ceq "127.0.0.1"', lifecycle)
        self.assertIn("The Store candidate contains a reparse point", lifecycle)
        self.assertIn("frozen QA signing state root must be one non-reparse directory", lifecycle)
        self.assertIn("sameSignedPackageVerified", lifecycle)
        self.assertNotIn("skipping wack", lifecycle.lower())
        prepare = (ROOT / "scripts" / "Prepare-MsixTestCandidate.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("New-SelfSignedCertificate", prepare)
        self.assertIn("KeyExportPolicy NonExportable", prepare)
        self.assertGreaterEqual(prepare.count("-DeleteKey"), 2)
        self.assertNotIn("Export-PfxCertificate", prepare)
        self.assertIn("Private QA signing material was not removed", prepare)
        self.assertIn("unsigned QA candidate contains a reparse point", prepare)
        self.assertIn("LAIZEYU.SurveyDataWorkbenchbyLAIZEYU", build_workflow)
        self.assertIn("CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8", build_workflow)
        self.assertNotIn("-Development", build_workflow)
        cleanup = (ROOT / "scripts" / "Cleanup-MsixTestCandidate.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8", cleanup)
        self.assertIn("direct statflow-msix-test-* child of RUNNER_TEMP", cleanup)
        self.assertIn("reparse point", cleanup)
        self.assertNotIn("CN=StatFlowDevelopment", cleanup)
        main_window = (
            ROOT / "desktop" / "StatFlow.Workbench.Desktop" / "MainWindow.xaml.cs"
        ).read_text(encoding="utf-8")
        self.assertNotIn("ci-evidence", main_window.lower())
        self.assertNotIn("ExecuteScriptAsync", main_window)

        public_evidence = (ROOT / "scripts" / "New-PublicWindowsGateEvidence.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("Length -gt 32KB", public_evidence)
        self.assertIn("Length -le 20", public_evidence)

    def test_github_binary_gate_requires_exact_trusted_author_signer(self) -> None:
        gate = (ROOT / "scripts" / "Verify-GitHubReleaseSignature.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn('Status -ne "Valid"', gate)
        self.assertIn('GetNameInfo(', gate)
        self.assertIn('@("LAI ZEYU", "来泽宇")', gate)
        self.assertIn("never an archive or certificate", gate)
        self.assertIn("TimeStamperCertificate", gate)
        self.assertIn("X509Chain", gate)
        self.assertIn("Online", gate)
        self.assertIn("1.3.6.1.5.5.7.3.3", gate)
        self.assertIn("self-issued signer certificate", gate)
        self.assertIn("SPC_RFC3161_OBJID", gate)
        self.assertIn("Assert-SignToolOutputPolicy", gate)
        self.assertIn("Number of warnings", gate)
        self.assertIn("exactly one aligned WIN_CERTIFICATE", gate)
        self.assertIn("AppxManifest Publisher", gate)

        cloud_signer = (ROOT / "scripts" / "Invoke-SslEsignerSign.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("Get-AppPackageManifestPublisher", cloud_signer)
        self.assertIn("manifestPublisher -cne", cloud_signer)
        self.assertIn('".msix", ".appx"', cloud_signer)
        self.assertNotIn("PfxPath", cloud_signer)
        self.assertIn("Trusted-WindowsSdkTool.ps1", cloud_signer)
        self.assertIn('Get-TrustedWindowsSdkTool -Name "signtool.exe"', cloud_signer)
        self.assertIn("Trusted-WindowsSdkTool.ps1", gate)
        self.assertIn('Get-TrustedWindowsSdkTool -Name "signtool.exe"', gate)

        workflow = (ROOT / ".github" / "workflows" / "windows-github-release.yml").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("CodeSignTool", workflow)
        self.assertNotIn("Invoke-SslEsignerMsix.ps1", workflow)
        self.assertNotIn("Build-Msix.ps1", workflow)
        self.assertNotIn("Initialize-SslEsignerCka.ps1", workflow)
        self.assertIn("SIGNING_HARNESS_PATH", workflow)
        self.assertIn("verify-signed-installer-lifecycle", workflow)
        self.assertIn("--passes 2", workflow)
        self.assertNotIn("secrets.SSL_ESIGNER_TOTP_SECRET", workflow)
        self.assertIn("SPSS_RELEASE_VALIDATION_APPROVED", workflow)
        self.assertIn("SPSS_ASSERTION_1_JSON", workflow)
        self.assertIn("verify_spss_release_attestations.py", workflow)
        self.assertIn("approved_layout_digest", workflow)
        self.assertIn("source-commit-and-integration-contract", (
            ROOT / "scripts" / "verify_spss_release_attestations.py"
        ).read_text(encoding="utf-8"))
        self.assertNotIn("gh release create", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertNotIn("actions/upload-artifact", workflow)
        self.assertNotIn("actions/download-artifact", workflow)
        self.assertIn("group: trusted-windows-release-build", workflow)
        self.assertIn("group: trusted-windows-release-review", workflow)
        self.assertIn("group: trusted-windows-release-signing", workflow)
        self.assertIn("group: trusted-windows-release-verifier", workflow)
        self.assertIn("group: trusted-windows-release-publisher", workflow)
        self.assertIn("group: trusted-windows-release-cleanup", workflow)
        signer = workflow.split("\n  sign-release-in-clean-domain:", 1)[1].split(
            "\n  verify-signed-release-in-clean-domain:", 1
        )[0]
        self.assertNotIn("actions/checkout", signer)
        self.assertNotIn("GH_TOKEN:", signer)
        self.assertNotIn("verify-signed-installer-lifecycle", signer)
        self.assertNotIn("--passes 2", signer)
        self.assertNotIn("Start-Process", signer)
        self.assertIn("--forbid-candidate-execution", signer)
        self.assertIn("candidateExecutionPerformedInSigningDomain -ne $false", signer)
        self.assertIn("longLivedTotpSeedExposedToCommandLine", signer)
        verifier = workflow.split(
            "\n  verify-signed-release-in-clean-domain:", 1
        )[1].split("\n  publish-release:", 1)[0]
        self.assertNotIn("actions/checkout", verifier)
        self.assertNotIn("GH_TOKEN:", verifier)
        self.assertNotIn("SIGNING_HARNESS_PATH", verifier)
        self.assertNotIn("secrets.SSL_ESIGNER", verifier)
        self.assertNotIn("Initialize-SslEsignerCka", verifier)
        self.assertIn("signingCredentialPresent -ne $false", verifier)
        self.assertIn("expected-executable-name 'StatFlow.Workbench.Desktop.exe'", verifier)
        self.assertIn("listenerProcessId", verifier)
        self.assertIn("uninstallRegistryRemoved", verifier)
        publisher = workflow.split("\n  publish-release:", 1)[1]
        self.assertNotIn("actions/checkout", publisher)
        self.assertIn("contents: write", publisher)
        self.assertIn("[long]$ownedId = 0", publisher)
        self.assertIn("Request POST", publisher)
        self.assertIn("No lookup/adoption is attempted", publisher)
        self.assertIn("Exact-ID asset upload", publisher)
        self.assertIn("Final public asset identity changed", publisher)
        self.assertIn("PUBLISH_REDOWNLOAD_ROOT", publisher)
        self.assertIn("publish.v3.json", publisher)
        self.assertIn("lifecycle-evidence.v1.json", publisher)
        self.assertIn("EXPECTED_SIGNING_HARNESS_SHA256", publisher)
        self.assertIn("EXPECTED_VERIFICATION_HARNESS_SHA256", publisher)
        self.assertIn("Recursive PE inventory does not bind the final installer entry", workflow)
        self.assertIn("git/tags/$objectSha", publisher)
        self.assertIn("git/ref/heads/main", publisher)
        self.assertIn("exact current main", publisher)
        self.assertNotIn("Invoke-GhJson", publisher)
        self.assertIn("not independent cryptographic attestations", publisher)

        def assert_handoff_isolation(policy: str) -> None:
            assert policy.count("publish-handoff") == 3
            assert "transition-handoff" in policy
            assert policy.count("assert-handoff") == 8
            assert policy.count("--forbid-writer") == 9
            assert policy.count("RELEASE_HANDOFF_OWNER_PRINCIPAL") == 6
            assert "RELEASE_CLEANUP_PRINCIPAL" in policy
            assert policy.count("trusted-windows-release-cleanup") == 2
            assert "private-verified-release-publication" in policy

        assert_handoff_isolation(workflow)
        negative_controls = (
            workflow.replace("--forbid-writer", "--allow-writer", 1),
            workflow.replace("publish-handoff", "copy-handoff", 1),
            workflow.replace("RELEASE_HANDOFF_OWNER_PRINCIPAL", "RELEASE_BUILD_PRINCIPAL", 1),
            workflow.replace("trusted-windows-release-cleanup", "trusted-windows-release-build", 1),
        )
        for unsafe_policy in negative_controls:
            with self.assertRaises(AssertionError):
                assert_handoff_isolation(unsafe_policy)

        initialize = (ROOT / "scripts" / "Initialize-SslEsignerCka.ps1").read_text(
            encoding="utf-8"
        )
        cleanup_cka = (ROOT / "scripts" / "Cleanup-SslEsignerCka.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("CredentialBrokerPath", initialize)
        self.assertNotIn("SSL_ESIGNER_TOTP_SECRET", initialize)
        self.assertIn("providerBaseline", initialize)
        self.assertIn("currentUserKeyFileBaseline", initialize)
        self.assertIn('"machine|$_"', initialize)
        self.assertIn('"current-user|$_"', initialize)
        self.assertIn("-DeleteKey", initialize)
        self.assertIn("-DeleteKey", cleanup_cka)
        self.assertIn("uninstallerSha256", cleanup_cka)
        self.assertIn("Compare-Object", cleanup_cka)
        self.assertIn("reparse point", cleanup_cka)

    def test_desktop_enforces_job_object_and_parent_watchdog(self) -> None:
        backend_host = (
            ROOT / "desktop" / "StatFlow.Workbench.Desktop" / "BackendHost.cs"
        ).read_text(encoding="utf-8")
        job_object = (
            ROOT / "desktop" / "StatFlow.Workbench.Desktop" / "KillOnCloseJob.cs"
        ).read_text(encoding="utf-8")
        self.assertIn("KillOnCloseJob.Create()", backend_host)
        self.assertIn('ArgumentList.Add("--parent-pid")', backend_host)
        self.assertIn("JobObjectLimitKillOnJobClose", job_object)
        self.assertIn("AssignProcessToJobObject", job_object)

    def test_store_identity_legal_layout_and_deletion_scope_are_explicit(self) -> None:
        manifest = (ROOT / "packaging" / "AppxManifest.template.xml").read_text(encoding="utf-8")
        build_msix = (ROOT / "scripts" / "Build-Msix.ps1").read_text(encoding="utf-8")
        build_windows = (ROOT / "scripts" / "Build-Windows.ps1").read_text(encoding="utf-8")
        info_dialog = (ROOT / "frontend" / "src" / "components" / "InfoDialog.jsx").read_text(
            encoding="utf-8"
        )
        self.assertIn("<PublisherDisplayName>__PUBLISHER_DISPLAY_NAME__</PublisherDisplayName>", manifest)
        self.assertIn('Executable="StatFlow.Workbench.Desktop.exe"', manifest)
        self.assertIn('$PublisherDisplayName = "LAI ZEYU"', build_msix)
        self.assertIn("exact Partner Center", build_msix)
        self.assertIn('"LAIZEYU.SurveyDataWorkbenchbyLAIZEYU"', build_msix)
        self.assertIn('"CN=A5F91D0A-30C6-48EE-944F-B767FA872BE8"', build_msix)
        self.assertIn('$ExpectedStoreVersion = "1.1.0.0"', build_msix)
        self.assertIn('$Version -cne $ExpectedStoreVersion', build_msix)
        self.assertNotIn("Get-Command makeappx.exe", build_msix)
        self.assertIn("Get-TrustedWindowsSdkTool", build_msix)
        self.assertIn('$PublisherDisplayName -cne "LAI ZEYU"', build_msix)
        self.assertIn("$SigningStatePath", build_msix)
        self.assertIn("Invoke-SslEsignerSign.ps1", build_msix)
        self.assertNotIn("PfxPath", build_msix)
        self.assertNotIn("STATFLOW_CERT_PASSWORD", build_msix)
        lifecycle = (ROOT / "scripts" / "Test-MsixLifecycle.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn('$PublisherDisplayName -cne "LAI ZEYU"', lifecycle)
        for legal_name in (
            "LICENSE.txt",
            "NOTICE.md",
            "THIRD_PARTY_NOTICES_SUMMARY.md",
            "THIRD_PARTY_NOTICES.txt",
        ):
            self.assertIn(legal_name, build_windows)
        self.assertIn("删除全部任务数据", info_dialog)
        self.assertIn("保留期设置、技术日志和 WebView2 支持数据不会由此按钮删除", info_dialog)
        generator = (ROOT / "scripts" / "Generate-ThirdPartyNotices.py").read_text(
            encoding="utf-8"
        )
        self.assertIn('EXPECTED_PYTHON = (3, 12, 10)', generator)
        self.assertIn('EXPECTED_DOTNET_RUNTIME = "8.0.30"', generator)
        self.assertIn('EXPECTED_WEBVIEW2 = "1.0.4129.50"', generator)
        self.assertIn("Installed Python distribution", generator)
        self.assertIn("is absent from the exact lock files", generator)
        self.assertIn("runtime pack exposes no license/notice source", generator)
        self.assertIn("publish_inventory_section", generator)
        self.assertIn('actual_sdk = subprocess.run(', generator)
        self.assertIn("exposes no installed license/notice file", generator)
        self.assertIn("3.12.10", build_windows)
        global_json = json.loads((ROOT / "global.json").read_text(encoding="utf-8"))
        self.assertEqual(global_json["sdk"]["version"], "8.0.424")
        self.assertEqual(global_json["sdk"]["rollForward"], "disable")

    def test_store_listing_and_effective_privacy_policy_have_no_submission_placeholders(self) -> None:
        privacy = (ROOT / "store" / "PRIVACY_POLICY.md").read_text(encoding="utf-8")
        listing = (ROOT / "store" / "LISTING.md").read_text(encoding="utf-8")
        checklist = (ROOT / "store" / "STORE_SUBMISSION_CHECKLIST.md").read_text(
            encoding="utf-8"
        )
        self.assertIn("**Effective date:** 27 August 2026", privacy)
        self.assertIn("/blob/main/store/PRIVACY_POLICY.md", privacy)
        self.assertIn("/security/advisories/new", privacy)
        self.assertNotIn("Draft effective date", privacy)
        self.assertNotIn("replace this paragraph", privacy.lower())
        self.assertNotIn("This draft must", privacy)
        self.assertIn("Recommended Store category: **Productivity**", listing)
        self.assertIn("at least 1366×768", listing)
        self.assertIn("macOS browser automation", listing)
        self.assertIn("Live Partner Center input", checklist)

    def test_parent_watchdog_detects_process_and_closes_for_dead_parent(self) -> None:
        self.assertTrue(parent_is_alive(os.getpid()))
        stop = threading.Event()
        closed: list[bool] = []
        with patch("server.parent_is_alive", return_value=False):
            watch_parent(424242, stop, lambda: closed.append(True), interval_seconds=0.001)
        self.assertEqual(closed, [True])

    def test_synthetic_fixture_is_detected(self) -> None:
        inspected = inspect_dataset(FIXTURE, FIXTURE.name)
        self.assertEqual(inspected["rows"], 48)
        self.assertEqual(inspected["columnCount"], 13)
        names = {construct["name"] for construct in inspected["detectedConstructs"]}
        self.assertEqual(names, {"ATT", "FQ", "MPO", "PU"})

    def test_dataset_resource_budgets_fail_closed_before_analysis(self) -> None:
        class ShapeOnly:
            def __init__(self, shape: tuple[int, int]) -> None:
                self.shape = shape

        with self.assertRaisesRegex(ValueError, "行安全上限"):
            _validate_dataset_shape(ShapeOnly((MAX_DATASET_ROWS + 1, 1)))
        with self.assertRaisesRegex(ValueError, "数据列数"):
            _validate_dataset_shape(ShapeOnly((1, MAX_DATASET_COLUMNS + 1)))
        with self.assertRaisesRegex(ValueError, "单元格总数"):
            _validate_dataset_shape(ShapeOnly((100_000, MAX_DATASET_CELLS // 100_000 + 1)))

    def test_normalized_column_collisions_are_rejected(self) -> None:
        frame = pd.DataFrame([[1, 2, 3]], columns=[" Score ", "score", "Other"])
        with self.assertRaisesRegex(ValueError, "列名.*冲突"):
            normalize_dataset_columns(frame)

    def test_import_rejects_duplicate_literal_headers_before_pandas_mangles_them(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            csv_path = Path(directory) / "duplicate.csv"
            csv_path.write_text("Score,Score,Other\n1,2,3\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "列名.*冲突"):
                read_dataset(csv_path)

            xlsx_path = Path(directory) / "duplicate.xlsx"
            pd.DataFrame([[1, 2, 3]], columns=[" Score ", "score", "Other"]).to_excel(
                xlsx_path,
                index=False,
            )
            with self.assertRaisesRegex(ValueError, "列名.*冲突"):
                read_dataset(xlsx_path)

    def test_excel_archive_traversal_and_compression_bombs_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            traversal = Path(directory) / "traversal.xlsx"
            with zipfile.ZipFile(traversal, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("../outside.xml", "x")
            with self.assertRaisesRegex(ValueError, "不安全"):
                _preflight_excel_archive(traversal)

            bomb = Path(directory) / "bomb.xlsx"
            with zipfile.ZipFile(bomb, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("xl/worksheets/sheet1.xml", b"0" * (2 * 1024 * 1024))
            with self.assertRaisesRegex(ValueError, "压缩比异常"):
                _preflight_excel_archive(bomb)

            corrupt = Path(directory) / "corrupt.xlsx"
            with zipfile.ZipFile(corrupt, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("xl/workbook.xml", os.urandom(8192))
            damaged = bytearray(corrupt.read_bytes())
            name_length = int.from_bytes(damaged[26:28], "little")
            extra_length = int.from_bytes(damaged[28:30], "little")
            compressed_size = int.from_bytes(damaged[18:22], "little")
            compressed_start = 30 + name_length + extra_length
            damaged[compressed_start + max(1, compressed_size // 2)] ^= 0xFF
            corrupt.write_bytes(damaged)
            with self.assertRaisesRegex(ValueError, "损坏|有效"):
                _preflight_excel_archive(corrupt)

    def test_bundle_rejects_linked_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            target = output / "safe.txt"
            target.write_text("safe", encoding="utf-8")
            linked = output / "linked.txt"
            try:
                linked.symlink_to(target)
            except (OSError, NotImplementedError):
                self.skipTest("symbolic links are unavailable on this test host")
            with self.assertRaisesRegex(ValueError, "符号链接"):
                make_bundle(output)

    def test_notice_generation_allows_only_missing_optional_npm_platform_packages(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "generate_third_party_notices",
            ROOT / "scripts" / "Generate-ThirdPartyNotices.py",
        )
        assert spec and spec.loader
        notices = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notices)
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            frontend = repo / "frontend"
            package_root = frontend / "node_modules" / "required-package"
            package_root.mkdir(parents=True)
            (package_root / "package.json").write_text(
                json.dumps({"name": "required-package", "version": "1.0.0", "license": "MIT"}),
                encoding="utf-8",
            )
            lock = {
                "lockfileVersion": 3,
                "packages": {
                    "": {},
                    "node_modules/required-package": {
                        "version": "1.0.0",
                        "integrity": "sha512-required",
                    },
                    "node_modules/other-platform-package": {
                        "version": "2.0.0",
                        "integrity": "sha512-optional",
                        "optional": True,
                        "os": ["aix"],
                    },
                },
            }
            lock_path = frontend / "package-lock.json"
            lock_path.write_text(json.dumps(lock), encoding="utf-8")
            sections = list(notices.frontend_sections(repo))
            self.assertEqual(len(sections), 1)
            self.assertIn("required-package 1.0.0", sections[0])

            lock["packages"]["node_modules/missing-required"] = {
                "version": "3.0.0",
                "integrity": "sha512-missing",
            }
            lock_path.write_text(json.dumps(lock), encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "Required locked npm package is not installed"):
                list(notices.frontend_sections(repo))

    def test_notice_generation_rejects_python_packages_absent_from_locks(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "generate_third_party_notices_python_inventory",
            ROOT / "scripts" / "Generate-ThirdPartyNotices.py",
        )
        assert spec and spec.loader
        notices = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(notices)
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            (repo / "requirements.lock.txt").write_text("pip==26.2.1\n", encoding="utf-8")
            (repo / "requirements-build.txt").write_text(
                "pip==26.2.1\n", encoding="utf-8"
            )
            installed = [
                types.SimpleNamespace(metadata={"Name": "pip"}, version="26.2.1"),
                types.SimpleNamespace(metadata={"Name": "unexpected-wheel"}, version="1.0.0"),
            ]
            with patch.object(notices.metadata, "distributions", return_value=installed):
                with self.assertRaisesRegex(RuntimeError, "absent from the exact lock files"):
                    list(notices.python_sections(repo))

    def test_spss_reader_without_safe_metadata_fails_before_row_allocation(self) -> None:
        calls: list[dict[str, object]] = []

        def unsafe_reader(_: str, **kwargs: object):
            calls.append(kwargs)
            if kwargs.get("metadataonly") is True:
                raise TypeError("metadata-only mode unavailable")
            self.fail("unsafe SPSS row allocation must not be attempted")

        fake = types.SimpleNamespace(read_sav=unsafe_reader, read_por=unsafe_reader)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "legacy.por"
            source.write_bytes(b"not-a-real-por")
            with patch.dict(sys.modules, {"pyreadstat": fake}):
                with self.assertRaisesRegex(ValueError, "安全解析前获取 SPSS 数据行列元数据"):
                    read_dataset(source)
        self.assertEqual(calls, [{"metadataonly": True}])

    def test_spss_reader_with_missing_declared_columns_fails_before_row_allocation(self) -> None:
        calls: list[dict[str, object]] = []

        def incomplete_metadata_reader(_: str, **kwargs: object):
            calls.append(kwargs)
            if kwargs.get("metadataonly") is True:
                metadata = types.SimpleNamespace(number_rows=10, column_names=[])
                return None, metadata
            self.fail("SPSS rows must not be allocated without a declared column budget")

        fake = types.SimpleNamespace(
            read_sav=incomplete_metadata_reader,
            read_por=incomplete_metadata_reader,
        )
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "missing-columns.por"
            source.write_bytes(b"not-a-real-por")
            with patch.dict(sys.modules, {"pyreadstat": fake}):
                with self.assertRaisesRegex(ValueError, "声明行列数超出安全范围"):
                    read_dataset(source)
        self.assertEqual(calls, [{"metadataonly": True}])

    def test_construct_detection_excludes_identifiers(self) -> None:
        frame = pd.read_csv(FIXTURE)
        names = {construct["name"] for construct in detect_constructs(frame)}
        self.assertNotIn("RESPONDENTID", names)

    def test_cronbach_alpha_is_finite_for_fixture(self) -> None:
        frame = pd.read_csv(FIXTURE)
        alpha = cronbach_alpha(frame[["FQ1", "FQ2", "FQ3"]])
        self.assertGreater(alpha, 0.70)
        self.assertLessEqual(alpha, 1.0)

    def test_portable_spss_driver_can_be_rebased_without_spss(self) -> None:
        prepared = pd.DataFrame(
            {"FQ1": [1, 2, 3], "FQ2": [1, 2, 3]}
        )
        constructs = [
            {
                "id": "fq",
                "name": "FQ",
                "label": "Feature quality",
                "items": ["FQ1", "FQ2"],
                "composite": "FQ",
            }
        ]
        with tempfile.TemporaryDirectory() as directory:
            original = Path(directory) / "original-build"
            original.mkdir()
            original_resolved = original.resolve()
            generate_spss_python_driver(
                prepared,
                constructs,
                [],
                ["descriptives", "reliability"],
                original,
            )
            template = original / "run_with_spss_python_portable.sps.in"
            helper = original / "prepare_portable_spss_run.py"
            external_driver = original / "run_with_spss_external.py"
            template_text = template.read_text(encoding="utf-8")
            self.assertIn(PORTABLE_STATUS_LITERAL_TOKEN, template_text)
            self.assertIn(PORTABLE_COMMAND_PATH_TOKEN, template_text)
            self.assertNotIn(str(original_resolved), template_text)
            driver_text = external_driver.read_text(encoding="utf-8")
            self.assertIn("spss.StartSPSS()", driver_text)
            self.assertIn("spss.Submit(commands)", driver_text)
            self.assertIn("spss.StopSPSS()", driver_text)
            compile(driver_text, str(external_driver), "exec")

            relocated = Path(directory) / "重定位 O'Brien (x86) & ^"
            relocated.mkdir()
            relocated_resolved = relocated.resolve()
            shutil.copy2(template, relocated / template.name)
            shutil.copy2(helper, relocated / helper.name)
            subprocess.run([sys.executable, str(relocated / helper.name)], check=True)
            portable = relocated / "run_with_spss_python_portable.sps"
            portable_text = portable.read_text(encoding="utf-8")

            status_match = re.search(r"^status_path = (.+)$", portable_text, re.MULTILINE)
            command_match = re.search(r"^commands = (.+)$", portable_text, re.MULTILINE)
            self.assertIsNotNone(status_match)
            self.assertIsNotNone(command_match)
            generated_status = ast.literal_eval(status_match.group(1))
            generated_commands = ast.literal_eval(command_match.group(1))

        self.assertNotIn(PORTABLE_STATUS_LITERAL_TOKEN, portable_text)
        self.assertNotIn(PORTABLE_COMMAND_PATH_TOKEN, portable_text)
        self.assertEqual(generated_status, str(relocated_resolved / "spss_python_status.json"))
        self.assertIn(str(relocated_resolved).replace("\\", "/").replace("'", "''"), generated_commands)
        self.assertNotIn(str(original_resolved), portable_text)

    def test_portable_template_rejects_raw_and_json_escaped_windows_path_leaks(self) -> None:
        original = r"C:\Users\来泽宇 O'Brien\Survey Data (x86)\job"
        status = original + r"\spss_python_status.json"
        status_literal = json.dumps(status, ensure_ascii=False)
        command_path = original.replace("\\", "/").replace("'", "''")
        syntax = f"status_path = {status_literal}\ncommands = {json.dumps(command_path, ensure_ascii=False)}\n"
        portable = build_portable_spss_template(
            syntax,
            status_literal=status_literal,
            spss_output_path=command_path,
            forbidden_paths={original, original.replace("\\", "/"), command_path},
        )
        self.assertIn(PORTABLE_STATUS_LITERAL_TOKEN, portable)
        self.assertIn(PORTABLE_COMMAND_PATH_TOKEN, portable)
        self.assertNotIn(original, portable)
        self.assertNotIn(json.dumps(original, ensure_ascii=False)[1:-1], portable)

        with self.assertRaisesRegex(ValueError, r"machine(?:-specific)? path"):
            build_portable_spss_template(
                syntax + f"# leaked={json.dumps(original, ensure_ascii=False)[1:-1]}",
                status_literal=status_literal,
                spss_output_path=command_path,
                forbidden_paths={original},
            )

    def test_python_marker_path_preserves_apostrophe(self) -> None:
        prepared = pd.DataFrame({"FQ1": [1, 2], "FQ2": [2, 3]})
        constructs = [
            {
                "id": "fq",
                "name": "FQ",
                "label": "Feature quality",
                "items": ["FQ1", "FQ2"],
                "composite": "FQ",
            }
        ]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "O'Brien survey"
            output.mkdir()
            generate_spss_python_driver(prepared, constructs, [], ["descriptives"], output)
            source = (output / "run_with_spss_external.py").read_text(encoding="utf-8")
            module = ast.parse(source)
            assignment = next(
                node
                for node in module.body
                if isinstance(node, ast.Assign)
                and any(getattr(target, "id", None) == "status_path" for target in node.targets)
            )
            generated_path = ast.literal_eval(assignment.value)

        self.assertEqual(generated_path, str((output / "spss_python_status.json").resolve()))
        self.assertIn("O'Brien", generated_path)
        self.assertNotIn("O''Brien", generated_path)

    def test_spss_names_and_labels_cannot_inject_syntax(self) -> None:
        self.assertEqual(sanitize_spss_name("ALL", set()), "V_ALL")
        prepared = pd.DataFrame({"V_ALL": [1, 2], "FQ2": [2, 3]})
        constructs = [
            {
                "id": "fq",
                "name": "ALL",
                "label": "Unsafe'\") ALL.\r\nERASE FILE='x",
                "items": ["V_ALL", "FQ2"],
                "composite": "SCALE_ALL",
            }
        ]
        with tempfile.TemporaryDirectory() as directory:
            syntax = generate_spss_python_driver(
                prepared,
                constructs,
                [],
                ["descriptives", "reliability"],
                Path(directory),
            ).read_text(encoding="utf-8")
        self.assertNotIn("\r", syntax)
        self.assertNotIn("ERASE FILE='x", syntax)
        self.assertIn("ERASE FILE=’x", syntax)

    def test_python_preview_workflow_produces_complete_bundle(self) -> None:
        inspected = inspect_dataset(FIXTURE, FIXTURE.name)
        config = {
            "constructs": inspected["detectedConstructs"],
            "models": [],
            "analyses": ["descriptives", "reliability", "correlations"],
            "executeSpss": False,
        }
        with tempfile.TemporaryDirectory() as directory:
            job = Path(directory)
            input_dir = job / "input"
            input_dir.mkdir()
            shutil.copy2(FIXTURE, input_dir / FIXTURE.name)
            result = execute_workflow(job, config)
            bundle = job / "outputs" / result["bundle"]
            with zipfile.ZipFile(bundle) as archive:
                corrupt = archive.testzip()
                names = set(archive.namelist())
                archived_content = b"\n".join(archive.read(name) for name in archive.namelist())

        self.assertEqual(result["state"], "complete")
        self.assertIsNone(corrupt)
        self.assertIn("analysis_summary.json", names)
        self.assertIn("run_with_spss_python_portable.sps.in", names)
        self.assertIn("prepare_portable_spss_run.py", names)
        self.assertNotIn("run_with_spss_python.sps", names)
        self.assertNotIn("run_with_spss_external.py", names)
        self.assertNotIn(str(job).encode(), archived_content)

    def test_failed_formal_run_discards_partial_outputs(self) -> None:
        inspected = inspect_dataset(FIXTURE, FIXTURE.name)
        config = {
            "constructs": inspected["detectedConstructs"],
            "models": [],
            "analyses": ["descriptives", "reliability", "correlations"],
            "executeSpss": True,
        }

        def failed_runner(_syntax: Path, output: Path):
            (output / "analysis_data.sav").write_bytes(b"partial")
            return {"state": "failed", "message": "expected test failure"}

        with tempfile.TemporaryDirectory() as directory:
            job = Path(directory)
            input_dir = job / "input"
            input_dir.mkdir()
            shutil.copy2(FIXTURE, input_dir / FIXTURE.name)
            with patch("analysis_engine.run_spss_automatically", side_effect=failed_runner):
                result = execute_workflow(job, config)
            outputs = job / "outputs"
            with zipfile.ZipFile(outputs / result["bundle"]) as archive:
                names = set(archive.namelist())

            self.assertEqual(result["spss"]["state"], "failed")
            self.assertIn("analysis_data.sav", result["spss"]["discardedPartialOutputs"])
            self.assertFalse((outputs / "analysis_data.sav").exists())
            self.assertTrue(set(EXPECTED_FORMAL_OUTPUTS).isdisjoint(names))

    def test_formal_marker_requires_all_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "spss_python_status.json").write_text(
                json.dumps({"status": "complete"}), encoding="utf-8"
            )
            self.assertEqual(marker_result(output, success_message="ok")["state"], "failed")

            import pyreadstat
            from pypdf import PdfWriter

            pyreadstat.write_sav(
                pd.DataFrame({"FQ1": [1.0, 2.0], "FQ2": [2.0, 3.0]}),
                str(output / "analysis_data.sav"),
            )
            with zipfile.ZipFile(output / "analysis_output.spv", "w") as archive:
                archive.writestr("outputViewer/document.xml", "<viewer />")
            writer = PdfWriter()
            writer.add_blank_page(width=612, height=792)
            with (output / "analysis_output.pdf").open("wb") as handle:
                writer.write(handle)
            verified = marker_result(output, success_message="ok")
        self.assertEqual(verified["state"], "complete")
        self.assertTrue(verified["formatIntegrityVerified"])
        self.assertFalse(verified["integrationVerified"])
        self.assertEqual(
            verified["semanticValidation"],
            "external_two_environment_gate_required",
        )
        self.assertEqual(set(verified["details"]["formatValidation"]), set(EXPECTED_FORMAL_OUTPUTS))

    def test_formal_marker_rejects_magic_only_pseudo_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "spss_python_status.json").write_text(
                json.dumps({"status": "complete"}), encoding="utf-8"
            )
            (output / "analysis_data.sav").write_bytes(b"$FL2 unreadable pseudo SAV")
            (output / "analysis_output.spv").write_bytes(b"PK unreadable pseudo SPV")
            (output / "analysis_output.pdf").write_bytes(b"%PDF- unreadable pseudo PDF")
            rejected = marker_result(output, success_message="ok")

        self.assertEqual(rejected["state"], "failed")
        self.assertEqual(set(rejected["details"]["invalidOutputFormats"]), {"SAV", "SPV", "PDF"})

    def test_formal_marker_fully_reads_sav_instead_of_metadata_only(self) -> None:
        import pyreadstat
        from pypdf import PdfWriter

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "spss_python_status.json").write_text(
                json.dumps({"status": "complete"}), encoding="utf-8"
            )
            sav = output / "analysis_data.sav"
            pyreadstat.write_sav(pd.DataFrame({"FQ1": [1.0, 2.0]}), str(sav))
            sav.write_bytes(sav.read_bytes()[:-1])
            with zipfile.ZipFile(output / "analysis_output.spv", "w") as archive:
                archive.writestr("outputViewer/document.xml", "<viewer />")
            writer = PdfWriter()
            writer.add_blank_page(width=612, height=792)
            with (output / "analysis_output.pdf").open("wb") as handle:
                writer.write(handle)
            rejected = marker_result(output, success_message="ok")

        self.assertEqual(rejected["state"], "failed")
        self.assertEqual(set(rejected["details"]["invalidOutputFormats"]), {"SAV"})

    def test_formal_marker_rejects_corrupt_compressed_pdf_stream(self) -> None:
        import pyreadstat
        from pypdf import PdfWriter
        from pypdf.generic import DecodedStreamObject, NameObject

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "spss_python_status.json").write_text(
                json.dumps({"status": "complete"}), encoding="utf-8"
            )
            pyreadstat.write_sav(
                pd.DataFrame({"FQ1": [1.0, 2.0]}),
                str(output / "analysis_data.sav"),
            )
            with zipfile.ZipFile(output / "analysis_output.spv", "w") as archive:
                archive.writestr("outputViewer/document.xml", "<viewer />")
            writer = PdfWriter()
            page = writer.add_blank_page(width=612, height=792)
            stream = DecodedStreamObject()
            stream.set_data(b"BT /F1 12 Tf 72 720 Td (Hello) Tj ET" * 20)
            page[NameObject("/Contents")] = writer._add_object(stream.flate_encode())
            pdf = output / "analysis_output.pdf"
            with pdf.open("wb") as handle:
                writer.write(handle)
            damaged = bytearray(pdf.read_bytes())
            stream_start = damaged.find(b"stream\n") + len(b"stream\n")
            self.assertGreaterEqual(stream_start, len(b"stream\n"))
            damaged[stream_start] ^= 0xFF
            pdf.write_bytes(damaged)
            rejected = marker_result(output, success_message="ok")

        self.assertEqual(rejected["state"], "failed")
        self.assertEqual(set(rejected["details"]["invalidOutputFormats"]), {"PDF"})

    def test_formal_marker_accepts_a_valid_empty_flate_pdf_stream(self) -> None:
        import pyreadstat
        from pypdf import PdfWriter
        from pypdf.generic import DecodedStreamObject, NameObject

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "spss_python_status.json").write_text(
                json.dumps({"status": "complete"}), encoding="utf-8"
            )
            pyreadstat.write_sav(
                pd.DataFrame({"FQ1": [1.0, 2.0]}),
                str(output / "analysis_data.sav"),
            )
            with zipfile.ZipFile(output / "analysis_output.spv", "w") as archive:
                archive.writestr("outputViewer/document.xml", "<viewer />")
            writer = PdfWriter()
            page = writer.add_blank_page(width=612, height=792)
            stream = DecodedStreamObject()
            stream.set_data(b"")
            page[NameObject("/Contents")] = writer._add_object(stream.flate_encode())
            with (output / "analysis_output.pdf").open("wb") as handle:
                writer.write(handle)
            accepted = marker_result(output, success_message="ok")

        self.assertEqual(accepted["state"], "complete")
        self.assertTrue(accepted["formatIntegrityVerified"])

    def test_formal_marker_returns_structured_failure_for_corrupt_deflated_spv(self) -> None:
        import pyreadstat
        from pypdf import PdfWriter

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "spss_python_status.json").write_text(
                json.dumps({"status": "complete"}), encoding="utf-8"
            )
            pyreadstat.write_sav(
                pd.DataFrame({"FQ1": [1.0, 2.0]}),
                str(output / "analysis_data.sav"),
            )
            spv = output / "analysis_output.spv"
            with zipfile.ZipFile(spv, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("outputViewer/document.xml", "<viewer>" + "A" * 8192 + "</viewer>")
            damaged = bytearray(spv.read_bytes())
            self.assertEqual(damaged[:4], b"PK\x03\x04")
            name_length = int.from_bytes(damaged[26:28], "little")
            extra_length = int.from_bytes(damaged[28:30], "little")
            compressed_size = int.from_bytes(damaged[18:22], "little")
            compressed_start = 30 + name_length + extra_length
            damaged[compressed_start + max(1, compressed_size // 3)] ^= 0xFF
            spv.write_bytes(damaged)
            writer = PdfWriter()
            writer.add_blank_page(width=612, height=792)
            with (output / "analysis_output.pdf").open("wb") as handle:
                writer.write(handle)
            rejected = marker_result(output, success_message="ok")

        self.assertEqual(rejected["state"], "failed")
        self.assertEqual(set(rejected["details"]["invalidOutputFormats"]), {"SPV"})

    def test_windows_detection_requires_vendor_launcher_and_python(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / "statisticspython3.bat").write_text("@echo off", encoding="utf-8")
            (home / "Python3").mkdir()
            missing_python = detect_windows_spss([home])
            self.assertFalse(missing_python["installed"])
            (home / "Python3" / "python.exe").write_bytes(b"test")
            detected = detect_windows_spss([home])
        self.assertTrue(detected["installed"])
        self.assertEqual(detected["licenseState"], "unverified")
        self.assertFalse(detected["integrationVerified"])
        public = public_spss_status(detected)
        self.assertNotIn("homePath", public)
        self.assertNotIn("pythonLauncher", public)

    def test_windows_command_paths_accept_unicode_spaces_and_apostrophes(self) -> None:
        value = r"C:\Users\来泽宇 O'Brien\Survey Data Workbench\driver.py"
        self.assertEqual(validate_cmd_path(value, label="test path"), value)

    def test_windows_command_paths_reject_shell_metacharacters(self) -> None:
        for character in '%!"\r\n':
            with self.subTest(character=character):
                with self.assertRaisesRegex(ValueError, "cannot be used safely"):
                    validate_cmd_path(f"C:\\unsafe{character}path\\driver.py", label="test path")

    def test_windows_cmd_invocation_quotes_parentheses_and_metacharacters(self) -> None:
        launcher = r"C:\Program Files (x86)\IBM & Research\statisticspython3.bat"
        driver = r"C:\Users\来泽宇 O'Brien\Survey ^ Data\run_with_spss_external.py"
        command = build_cmd_invocation(r"C:\Windows\System32\cmd.exe", launcher, driver)
        self.assertEqual(command[:5], [r"C:\Windows\System32\cmd.exe", "/d", "/v:off", "/s", "/c"])
        self.assertEqual(command[5], f'call "{launcher}" "{driver}"')

    @unittest.skipUnless(os.name == "nt", "requires the real Windows cmd.exe")
    def test_windows_cmd_invocation_round_trips_complex_quoted_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "来泽宇 O'Brien (x86) & ^"
            root.mkdir()
            launcher = root / "launcher & test.bat"
            output = root / "result ^ & (ok).txt"
            launcher.write_text('@echo off\r\n> "%~1" echo ok\r\n', encoding="utf-8")
            completed = subprocess.run(
                build_cmd_invocation(system_cmd_path(), launcher, output),
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(output.read_text(encoding="utf-8").strip(), "ok")

    def test_windows_command_processor_comes_from_system_directory_api(self) -> None:
        with (
            patch(
                "spss_runner.windows.system_directory_path",
                return_value=Path(r"C:\Windows\System32"),
            ),
            patch.object(Path, "is_file", return_value=True),
        ):
            resolved = system_cmd_path()
        self.assertEqual(resolved.name, "cmd.exe")
        source = (BACKEND / "spss_runner" / "windows.py").read_text(encoding="utf-8")
        self.assertIn("GetSystemDirectoryW", source)
        self.assertNotIn('os.environ.get("SystemRoot"', source)

    def test_windows_runner_uses_system_cmd_without_a_generated_wrapper(self) -> None:
        class FakeProcess:
            pid = 4242
            returncode = 1

            @staticmethod
            def communicate(timeout: int):
                del timeout
                return "", "expected marker-free test"

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "来泽宇 O'Brien survey"
            output.mkdir()
            driver = output / "run_with_spss_external.py"
            driver.write_text("raise SystemExit(1)\n", encoding="utf-8")
            runner = WindowsSpssRunner()
            installed = {
                "installed": True,
                "pythonLauncher": r"C:\Program Files\IBM SPSS O'Brien\statisticspython3.bat",
            }
            with (
                patch.object(runner, "status", return_value=installed),
                patch(
                    "spss_runner.windows.system_cmd_path",
                    return_value=Path(r"C:\Windows\System32\cmd.exe"),
                ),
                patch("spss_runner.windows.subprocess.Popen", return_value=FakeProcess()) as popen,
            ):
                result = runner.run(output / "run_with_spss_python.sps", output, 30)

            command = popen.call_args.args[0]
            self.assertEqual(command[:5], [r"C:\Windows\System32\cmd.exe", "/d", "/v:off", "/s", "/c"])
            self.assertEqual(
                command[5],
                'call "{}" "{}"'.format(installed["pythonLauncher"], driver),
            )
            self.assertEqual(popen.call_args.kwargs["cwd"], output)
            self.assertFalse((output / "run_spss_windows.cmd").exists())
            self.assertEqual(result["state"], "failed")

    def test_windows_runner_fails_closed_for_unsafe_job_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "unsafe%job"
            output.mkdir()
            (output / "run_with_spss_external.py").write_text("pass\n", encoding="utf-8")
            runner = WindowsSpssRunner()
            installed = {
                "installed": True,
                "pythonLauncher": r"C:\Program Files\IBM\SPSS\statisticspython3.bat",
            }
            with (
                patch.object(runner, "status", return_value=installed),
                patch("spss_runner.windows.subprocess.Popen") as popen,
            ):
                result = runner.run(output / "run_with_spss_python.sps", output, 30)

            popen.assert_not_called()
            self.assertEqual(result["state"], "failed")
            self.assertIn("拒绝了", result["message"])

    def test_windows_runner_timeout_never_calls_unbounded_communicate(self) -> None:
        class TimeoutProcess:
            pid = 4242
            returncode = None
            stdout = StringIO()
            stderr = StringIO()
            communicate_calls = 0
            killed = False

            @classmethod
            def communicate(cls, timeout: int):
                cls.communicate_calls += 1
                raise subprocess.TimeoutExpired("cmd.exe", timeout)

            @classmethod
            def poll(cls):
                return None

            @classmethod
            def kill(cls):
                cls.killed = True

            @staticmethod
            def wait(timeout: int):
                self.assertEqual(timeout, 15)
                return -9

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "timed out (x86)"
            output.mkdir()
            (output / "run_with_spss_external.py").write_text("pass\n", encoding="utf-8")
            runner = WindowsSpssRunner()
            installed = {
                "installed": True,
                "pythonLauncher": r"C:\Program Files (x86)\IBM\statisticspython3.bat",
            }
            with (
                patch.object(runner, "status", return_value=installed),
                patch(
                    "spss_runner.windows.system_cmd_path",
                    return_value=Path(r"C:\Windows\System32\cmd.exe"),
                ),
                patch(
                    "spss_runner.windows.system_directory_path",
                    return_value=Path(directory),
                ),
                patch("spss_runner.windows.subprocess.Popen", return_value=TimeoutProcess()),
            ):
                result = runner.run(output / "run_with_spss_python.sps", output, 1)

        self.assertEqual(result["state"], "timeout")
        self.assertEqual(TimeoutProcess.communicate_calls, 1)
        self.assertTrue(TimeoutProcess.killed)
        self.assertFalse(result["details"]["treeTerminationVerified"])


class ApiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        data_root = Path(self.temporary.name)
        self.app = create_app(
            {
                "TESTING": True,
                "DATA_ROOT": data_root,
                "JOBS_ROOT": data_root / "jobs",
                "API_TOKEN": "",
            }
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_health_endpoint(self) -> None:
        with self.app.test_client() as client:
            response = client.get("/api/health")
        self.assertEqual(response.status_code, 200)
        payload = response.get_json()
        self.assertTrue(payload["ok"])
        self.assertIn(".csv", payload["supportedFormats"])
        self.assertIn("installed", payload["spss"])

    def test_unsupported_upload_is_rejected(self) -> None:
        with self.app.test_client() as client:
            response = client.post(
                "/api/upload",
                data={"file": (BytesIO(b"not an executable"), "unsafe.exe")},
                content_type="multipart/form-data",
            )
        self.assertEqual(response.status_code, 400)
        self.assertIn("error", response.get_json())


class SecureApiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.data_root = Path(self.temporary.name)
        self.token = "test-token-with-at-least-thirty-two-characters"
        self.app = create_app(
            {
                "TESTING": True,
                "DATA_ROOT": self.data_root,
                "JOBS_ROOT": self.data_root / "jobs",
                "API_TOKEN": self.token,
                "RETENTION_DAYS": 30,
            }
        )
        self.client = self.app.test_client()
        self.headers = {"X-StatFlow-Token": self.token}

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def upload_fixture(self) -> dict:
        with FIXTURE.open("rb") as handle:
            response = self.client.post(
                "/api/upload",
                headers=self.headers,
                data={"file": (handle, FIXTURE.name)},
                content_type="multipart/form-data",
            )
        self.assertEqual(response.status_code, 200)
        return response.get_json()

    def test_token_host_origin_and_security_headers(self) -> None:
        missing = self.client.get("/api/health")
        self.assertEqual(missing.status_code, 401)
        wrong_host = self.client.get(
            "/api/health", headers=self.headers, base_url="http://example.invalid"
        )
        self.assertEqual(wrong_host.status_code, 400)
        wrong_origin = self.client.get(
            "/api/health", headers={**self.headers, "Origin": "https://example.invalid"}
        )
        self.assertEqual(wrong_origin.status_code, 403)
        response = self.client.get("/api/health", headers=self.headers)
        self.assertEqual(response.status_code, 200)
        self.assertIn("default-src 'self'", response.headers["Content-Security-Policy"])
        self.assertEqual(response.headers["X-Frame-Options"], "DENY")
        self.assertEqual(response.headers["Cross-Origin-Resource-Policy"], "same-origin")
        self.assertEqual(response.get_json()["formalOutputPolicy"], "format-integrity-only")
        self.assertEqual(
            response.get_json()["semanticValidationPolicy"],
            "external-two-authorised-environments",
        )

    def test_upload_does_not_expose_internal_paths_and_delete_all_works(self) -> None:
        uploaded = self.upload_fixture()
        self.assertNotIn("storedPath", uploaded)
        self.assertNotIn(str(self.data_root), json.dumps(uploaded))
        deleted = self.client.delete("/api/data", headers=self.headers)
        self.assertEqual(deleted.status_code, 204)
        self.assertEqual(list((self.data_root / "jobs").iterdir()), [])

    def test_formal_execution_fails_closed_when_spss_is_unavailable(self) -> None:
        uploaded = self.upload_fixture()
        config = {
            "sheet": uploaded.get("selectedSheet"),
            "constructs": uploaded["detectedConstructs"],
            "analyses": ["descriptives", "reliability", "correlations"],
            "models": [],
            "executeSpss": True,
        }
        unavailable = {
            "installed": False,
            "licenseState": "unavailable",
            "integrationVerified": False,
        }
        with patch("app.spss_status", return_value=unavailable):
            response = self.client.post(
                f"/api/jobs/{uploaded['jobId']}/run",
                headers={**self.headers, "Content-Type": "application/json"},
                json=config,
            )
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.get_json()["error"]["code"], "spss_unavailable")

    def test_preview_job_completes_without_formal_outputs(self) -> None:
        uploaded = self.upload_fixture()
        config = {
            "sheet": uploaded.get("selectedSheet"),
            "constructs": uploaded["detectedConstructs"],
            "analyses": ["descriptives", "reliability", "correlations"],
            "models": [],
            "executeSpss": False,
        }
        started = self.client.post(
            f"/api/jobs/{uploaded['jobId']}/run",
            headers={**self.headers, "Content-Type": "application/json"},
            json=config,
        )
        self.assertEqual(started.status_code, 202)
        payload = started.get_json()
        for _ in range(100):
            response = self.client.get(f"/api/jobs/{uploaded['jobId']}", headers=self.headers)
            payload = response.get_json()
            if payload["status"] != "running":
                break
            time.sleep(0.02)
        self.assertEqual(payload["status"], "complete")
        self.assertEqual(payload["result"]["spss"]["state"], "skipped")
        names = {item["name"] for item in payload["result"]["files"]}
        self.assertTrue(set(EXPECTED_FORMAL_OUTPUTS).isdisjoint(names))
        self.assertTrue(
            all(item["provenance"] == "preview_or_supporting_file" for item in payload["result"]["files"])
        )

        for _ in range(20):
            deleted = self.client.delete(f"/api/jobs/{uploaded['jobId']}", headers=self.headers)
            if deleted.status_code != 409:
                break
            time.sleep(0.01)
        self.assertEqual(deleted.status_code, 204)

    def test_requested_formal_failure_has_distinct_terminal_state(self) -> None:
        uploaded = self.upload_fixture()
        config = {
            "sheet": uploaded.get("selectedSheet"),
            "constructs": uploaded["detectedConstructs"],
            "analyses": ["descriptives", "reliability"],
            "models": [],
            "executeSpss": True,
        }
        installed = {"installed": True, "licenseState": "unverified", "integrationVerified": False}
        failed_result = {
            "state": "complete",
            "preview": {},
            "spss": {"state": "failed", "message": "expected formal failure"},
            "bundle": "Survey_Data_Workbench_完整产出.zip",
            "files": [],
        }
        with (
            patch("app.spss_status", return_value=installed),
            patch("app.execute_workflow", return_value=failed_result),
        ):
            started = self.client.post(
                f"/api/jobs/{uploaded['jobId']}/run",
                headers={**self.headers, "Content-Type": "application/json"},
                json=config,
            )
            self.assertEqual(started.status_code, 202)
            payload = started.get_json()
            for _ in range(100):
                payload = self.client.get(
                    f"/api/jobs/{uploaded['jobId']}", headers=self.headers
                ).get_json()
                if payload["status"] != "running":
                    break
                time.sleep(0.01)

        self.assertEqual(payload["status"], "formal_failed")
        self.assertEqual(payload["stage"], "formal_failed")
        self.assertEqual(payload["result"]["spss"]["state"], "failed")
        self.assertIn("正式输出未验证", payload["message"])

    def test_retention_setting_persists_and_purges_expired_jobs(self) -> None:
        old_job_id = str(__import__("uuid").uuid4())
        old_job = self.data_root / "jobs" / old_job_id
        old_job.mkdir()
        (old_job / "job.json").write_text(
            json.dumps(
                {
                    "jobId": old_job_id,
                    "createdAt": (utc_now() - timedelta(days=50)).isoformat(timespec="seconds"),
                    "status": "configured",
                }
            ),
            encoding="utf-8",
        )
        self.app.extensions["next_retention_purge"] = utc_now() - timedelta(seconds=1)
        health = self.client.get("/api/health", headers=self.headers)
        self.assertEqual(health.status_code, 200)
        self.assertFalse(old_job.exists())
        rejected_bool = self.client.put(
            "/api/settings",
            headers={**self.headers, "Content-Type": "application/json"},
            json={"retentionDays": True},
        )
        self.assertEqual(rejected_bool.status_code, 400)
        response = self.client.put(
            "/api/settings",
            headers={**self.headers, "Content-Type": "application/json"},
            json={"retentionDays": 45},
        )
        self.assertEqual(response.status_code, 200)
        reloaded = create_app(
            {
                "TESTING": True,
                "DATA_ROOT": self.data_root,
                "JOBS_ROOT": self.data_root / "jobs",
                "API_TOKEN": self.token,
            }
        )
        self.assertEqual(reloaded.config["RETENTION_DAYS"], 45)

    def test_interrupted_job_discards_formal_outputs_and_private_runner_files(self) -> None:
        job_id = str(__import__("uuid").uuid4())
        directory = self.data_root / "jobs" / job_id
        outputs = directory / "outputs"
        outputs.mkdir(parents=True)
        for name in EXPECTED_FORMAL_OUTPUTS:
            (outputs / name).write_bytes(b"partial")
        (outputs / "spss_python_status.json").write_text(
            json.dumps({"status": "complete", "traceback": str(self.data_root)}),
            encoding="utf-8",
        )
        (outputs / "run_with_spss_external.py").write_text(
            f"status_path = {str(self.data_root)!r}", encoding="utf-8"
        )
        (outputs / "Survey_Data_Workbench_完整产出.zip").write_bytes(b"stale")
        (directory / "job.json").write_text(
            json.dumps({"jobId": job_id, "status": "running", "result": {"spss": {"state": "complete"}}}),
            encoding="utf-8",
        )

        recovered = create_app(
            {
                "TESTING": True,
                "DATA_ROOT": self.data_root,
                "JOBS_ROOT": self.data_root / "jobs",
                "API_TOKEN": self.token,
            }
        )
        metadata = json.loads((directory / "job.json").read_text(encoding="utf-8"))
        self.assertEqual(metadata["status"], "failed")
        self.assertEqual(metadata["stage"], "interrupted")
        self.assertNotIn("result", metadata)
        self.assertTrue(set(EXPECTED_FORMAL_OUTPUTS).isdisjoint(path.name for path in outputs.iterdir()))
        self.assertFalse((outputs / "spss_python_status.json").exists())
        self.assertFalse((outputs / "Survey_Data_Workbench_完整产出.zip").exists())

        with recovered.test_client() as client:
            private_download = client.get(
                f"/api/jobs/{job_id}/download/run_with_spss_external.py",
                headers=self.headers,
            )
        self.assertEqual(private_download.status_code, 404)


if __name__ == "__main__":
    unittest.main()
