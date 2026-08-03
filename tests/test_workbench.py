from __future__ import annotations

import sys
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from io import BytesIO
from pathlib import Path
from unittest.mock import patch

import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "backend"
FIXTURE = ROOT / "examples" / "synthetic_survey.csv"
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))

from analysis_engine import (  # noqa: E402
    cronbach_alpha,
    detect_constructs,
    execute_workflow,
    generate_spss_python_driver,
    inspect_dataset,
)
from app import app, job_locks, run_job  # noqa: E402


class AnalysisEngineTests(unittest.TestCase):
    def test_synthetic_fixture_is_detected(self) -> None:
        inspected = inspect_dataset(FIXTURE, FIXTURE.name)
        self.assertEqual(inspected["rows"], 48)
        self.assertEqual(inspected["columnCount"], 13)
        names = {construct["name"] for construct in inspected["detectedConstructs"]}
        self.assertEqual(names, {"ATT", "FQ", "MPO", "PU"})

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
            output = Path(directory)
            generate_spss_python_driver(
                prepared,
                constructs,
                [],
                ["descriptives", "reliability"],
                output,
            )
            template = output / "run_with_spss_python_portable.sps.in"
            helper = output / "prepare_portable_spss_run.py"
            template_text = template.read_text(encoding="utf-8")
            self.assertIn("__SPSS_OUTPUT_DIR__", template_text)
            self.assertNotIn(str(output), template_text)

            subprocess.run([sys.executable, str(helper)], check=True)
            portable = output / "run_with_spss_python_portable.sps"
            portable_text = portable.read_text(encoding="utf-8")

        self.assertNotIn("__SPSS_OUTPUT_DIR__", portable_text)
        self.assertIn(str(output), portable_text)

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

        self.assertEqual(result["state"], "complete")
        self.assertIsNone(corrupt)
        self.assertIn("analysis_summary.json", names)
        self.assertIn("run_with_spss_python_portable.sps.in", names)
        self.assertIn("prepare_portable_spss_run.py", names)


class ApiTests(unittest.TestCase):
    def test_health_endpoint(self) -> None:
        with app.test_client() as client:
            response = client.get("/api/health")
        self.assertEqual(response.status_code, 200)
        payload = response.get_json()
        self.assertTrue(payload["ok"])
        self.assertIn(".csv", payload["supportedFormats"])
        self.assertIn("installed", payload["spss"])
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        self.assertEqual(response.headers["X-Content-Type-Options"], "nosniff")

    def test_unsupported_upload_is_rejected(self) -> None:
        with app.test_client() as client:
            response = client.post(
                "/api/upload",
                data={"file": (BytesIO(b"not an executable"), "unsafe.exe")},
                content_type="multipart/form-data",
            )
        self.assertEqual(response.status_code, 400)
        self.assertIn("error", response.get_json())

    def test_background_job_lock_is_released_after_completion(self) -> None:
        job_id = "00000000-0000-0000-0000-000000000001"
        metadata = {"jobId": job_id, "status": "running"}
        saved: list[dict] = []
        with tempfile.TemporaryDirectory() as directory:
            with patch("app.job_dir", return_value=Path(directory)), patch(
                "app.load_job", side_effect=[metadata.copy(), metadata.copy()]
            ):
                with patch(
                    "app.execute_workflow", return_value={"state": "complete"}
                ), patch(
                    "app.save_job",
                    side_effect=lambda _job_id, value: saved.append(value),
                ):
                    run_job(job_id, {"executeSpss": False})

        self.assertNotIn(job_id, job_locks)
        self.assertEqual(saved[-1]["status"], "complete")


if __name__ == "__main__":
    unittest.main()
