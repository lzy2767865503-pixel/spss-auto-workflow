from __future__ import annotations

import json
import mimetypes
import os
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Any, Iterator

from flask import Flask, jsonify, request, send_from_directory
from werkzeug.exceptions import HTTPException
from werkzeug.utils import secure_filename

from analysis_engine import (
    SUPPORTED_EXTENSIONS,
    execute_workflow,
    inspect_dataset,
    output_inventory,
    spss_status,
)


ROOT = Path(__file__).resolve().parents[1]
FRONTEND_DIST = ROOT / "frontend" / "dist"
JOBS_ROOT = ROOT / "data" / "jobs"
JOBS_ROOT.mkdir(parents=True, exist_ok=True)

app = Flask(__name__, static_folder=str(FRONTEND_DIST), static_url_path="")
app.config["MAX_CONTENT_LENGTH"] = 200 * 1024 * 1024
job_locks: dict[str, tuple[Any, int]] = {}
job_locks_guard = threading.Lock()


@contextmanager
def hold_job_lock(job_id: str) -> Iterator[None]:
    with job_locks_guard:
        current = job_locks.get(job_id)
        if current is None:
            lock, users = threading.Lock(), 0
        else:
            lock, users = current
        job_locks[job_id] = (lock, users + 1)
    try:
        with lock:
            yield
    finally:
        with job_locks_guard:
            current = job_locks.get(job_id)
            if current and current[0] is lock:
                if current[1] <= 1:
                    job_locks.pop(job_id, None)
                else:
                    job_locks[job_id] = (lock, current[1] - 1)


def job_dir(job_id: str) -> Path:
    if not job_id or any(character not in "0123456789abcdef-" for character in job_id.lower()):
        raise ValueError("无效任务编号")
    return JOBS_ROOT / job_id


def metadata_path(job_id: str) -> Path:
    return job_dir(job_id) / "job.json"


def load_job(job_id: str) -> dict[str, Any]:
    path = metadata_path(job_id)
    if not path.exists():
        raise FileNotFoundError(job_id)
    return json.loads(path.read_text(encoding="utf-8"))


def save_job(job_id: str, metadata: dict[str, Any]) -> None:
    metadata_path(job_id).write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def public_job(metadata: dict[str, Any]) -> dict[str, Any]:
    copied = dict(metadata)
    copied.pop("storedPath", None)
    return copied


@app.after_request
def harden_response(response):
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    if request.path.startswith("/api/"):
        response.headers["Cache-Control"] = "no-store"
    return response


@app.errorhandler(413)
def too_large(_: Exception):
    return jsonify({"error": "文件超过 200MB，请先拆分或压缩数据。"}), 413


@app.errorhandler(Exception)
def handle_error(error: Exception):
    if isinstance(error, HTTPException):
        return jsonify({"error": error.description}), error.code
    status = 404 if isinstance(error, FileNotFoundError) else 400
    return jsonify({"error": str(error) or error.__class__.__name__}), status


@app.get("/api/health")
def health():
    return jsonify(
        {
            "ok": True,
            "name": "SPSS 自动分析台",
            "spss": spss_status(),
            "supportedFormats": sorted(SUPPORTED_EXTENSIONS),
        }
    )


@app.get("/favicon.ico")
def favicon():
    return "", 204


@app.post("/api/upload")
def upload():
    uploaded = request.files.get("file")
    if uploaded is None or not uploaded.filename:
        return jsonify({"error": "请选择一个数据文件"}), 400
    suffix = Path(uploaded.filename).suffix.lower()
    if suffix not in SUPPORTED_EXTENSIONS:
        return jsonify({"error": f"暂不支持 {suffix or '该'} 格式"}), 400

    job_id = str(uuid.uuid4())
    directory = job_dir(job_id)
    input_dir = directory / "input"
    input_dir.mkdir(parents=True)
    safe_name = secure_filename(uploaded.filename) or f"dataset{suffix}"
    stored = input_dir / f"dataset{suffix}"
    uploaded.save(stored)
    inspected = inspect_dataset(stored, uploaded.filename)
    metadata = {
        "jobId": job_id,
        "createdAt": datetime.now().isoformat(timespec="seconds"),
        "status": "configured",
        "stage": "upload",
        "progress": 0,
        "message": "数据已读取，可以配置分析",
        "safeName": safe_name,
        **inspected,
    }
    save_job(job_id, metadata)
    return jsonify(public_job(metadata))


@app.post("/api/jobs/<job_id>/sheet")
def change_sheet(job_id: str):
    metadata = load_job(job_id)
    payload = request.get_json(force=True)
    selected = str(payload.get("sheet") or "")
    stored = Path(metadata["storedPath"])
    inspected = inspect_dataset(stored, metadata["fileName"], selected)
    metadata.update(inspected)
    metadata.update({"status": "configured", "message": f"已切换到工作表：{selected}"})
    save_job(job_id, metadata)
    return jsonify(public_job(metadata))


def run_job(job_id: str, config: dict[str, Any]) -> None:
    with hold_job_lock(job_id):
        metadata = load_job(job_id)

        def update(stage: str, progress: int, message: str) -> None:
            current = load_job(job_id)
            current.update(
                {
                    "status": "running",
                    "stage": stage,
                    "progress": progress,
                    "message": message,
                    "updatedAt": datetime.now().isoformat(timespec="seconds"),
                }
            )
            save_job(job_id, current)

        try:
            result = execute_workflow(job_dir(job_id), config, update)
            metadata = load_job(job_id)
            metadata.update(
                {
                    "status": "complete",
                    "stage": "complete",
                    "progress": 100,
                    "message": "分析与文件整理已完成",
                    "result": result,
                    "config": config,
                    "completedAt": datetime.now().isoformat(timespec="seconds"),
                }
            )
        except Exception as error:
            metadata = load_job(job_id)
            outputs = job_dir(job_id) / "outputs"
            metadata.update(
                {
                    "status": "failed",
                    "stage": "failed",
                    "message": str(error),
                    "error": str(error),
                    "files": output_inventory(outputs) if outputs.exists() else [],
                }
            )
        save_job(job_id, metadata)


@app.post("/api/jobs/<job_id>/run")
def start_job(job_id: str):
    metadata = load_job(job_id)
    if metadata.get("status") == "running":
        return jsonify({"error": "该任务正在运行"}), 409
    config = request.get_json(force=True)
    metadata.update(
        {
            "status": "running",
            "stage": "queued",
            "progress": 3,
            "message": "任务已进入自动分析队列",
            "config": config,
        }
    )
    save_job(job_id, metadata)
    thread = threading.Thread(target=run_job, args=(job_id, config), daemon=True)
    thread.start()
    return jsonify(public_job(metadata)), 202


@app.get("/api/jobs/<job_id>")
def get_job(job_id: str):
    return jsonify(public_job(load_job(job_id)))


@app.get("/api/jobs/<job_id>/download/<path:filename>")
def download(job_id: str, filename: str):
    outputs = (job_dir(job_id) / "outputs").resolve()
    target = (outputs / filename).resolve()
    if outputs not in target.parents or not target.is_file():
        raise FileNotFoundError(filename)
    mimetype = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
    return send_from_directory(outputs, target.name, as_attachment=True, mimetype=mimetype)


@app.get("/")
@app.get("/<path:path>")
def frontend(path: str = ""):
    if path and (FRONTEND_DIST / path).is_file():
        return send_from_directory(FRONTEND_DIST, path)
    index = FRONTEND_DIST / "index.html"
    if not index.exists():
        return (
            "前端尚未构建。请在 frontend 目录运行 npm install && npm run build。",
            503,
        )
    return send_from_directory(FRONTEND_DIST, "index.html")


if __name__ == "__main__":
    port = int(os.environ.get("SPSS_AUTO_PORT", "8765"))
    app.run(host="127.0.0.1", port=port, threaded=True, debug=False)
