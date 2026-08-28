from __future__ import annotations

import json
import mimetypes
import os
import secrets
import shutil
import sys
import threading
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from flask import Flask, jsonify, request, send_from_directory
from werkzeug.exceptions import HTTPException
from werkzeug.utils import secure_filename

from analysis_engine import (
    MACHINE_SPECIFIC_OUTPUTS,
    MAX_DATASET_BYTES,
    SUPPORTED_EXTENSIONS,
    execute_workflow,
    inspect_dataset,
    output_inventory,
)
from spss_runner import EXPECTED_FORMAL_OUTPUTS, public_spss_status, spss_status


ROOT = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[1]))
FRONTEND_DIST = ROOT / "frontend" / "dist"
ALLOWED_ANALYSES = {"descriptives", "reliability", "correlations", "factor", "regression"}
LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}
PRIVATE_KEYS = {
    "appPath",
    "binaryPath",
    "bundledPython",
    "details",
    "homePath",
    "pythonLauncher",
    "storedPath",
    "stderr",
    "stdout",
    "traceback",
}


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def default_data_root() -> Path:
    configured = os.environ.get("STATFLOW_DATA_DIR")
    if configured:
        return Path(configured).expanduser()
    if os.name == "nt":
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
    elif sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return base / "LAI Systems" / "Survey Data Workbench"


def _error(message: str, code: str, status: int):
    return jsonify({"error": {"code": code, "message": message}}), status


def _uuid(value: str) -> str:
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise ValueError("无效任务编号") from error
    canonical = str(parsed)
    if value.lower() != canonical:
        raise ValueError("无效任务编号")
    return canonical


def _jobs_root(app: Flask) -> Path:
    return Path(app.config["JOBS_ROOT"])


def job_dir(app: Flask, job_id: str) -> Path:
    return _jobs_root(app) / _uuid(job_id)


def metadata_path(app: Flask, job_id: str) -> Path:
    return job_dir(app, job_id) / "job.json"


def load_job(app: Flask, job_id: str) -> dict[str, Any]:
    path = metadata_path(app, job_id)
    if not path.is_file():
        raise FileNotFoundError(job_id)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError("任务元数据损坏，无法继续") from error
    if not isinstance(value, dict):
        raise ValueError("任务元数据损坏，无法继续")
    return value


def save_job(app: Flask, job_id: str, metadata: dict[str, Any]) -> None:
    destination = metadata_path(app, job_id)
    temporary = destination.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(destination)


def _scrub(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: _scrub(item) for key, item in value.items() if key not in PRIVATE_KEYS}
    if isinstance(value, list):
        return [_scrub(item) for item in value]
    return value


def public_job(metadata: dict[str, Any]) -> dict[str, Any]:
    return _scrub(metadata)


def _created_at(metadata: dict[str, Any], directory: Path) -> datetime:
    raw = metadata.get("createdAt")
    if isinstance(raw, str):
        try:
            parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
            return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return datetime.fromtimestamp(directory.stat().st_mtime, tz=timezone.utc)


def purge_expired_jobs(app: Flask) -> int:
    cutoff = utc_now() - timedelta(days=int(app.config["RETENTION_DAYS"]))
    removed = 0
    active: set[str] = app.extensions["active_jobs"]
    for directory in _jobs_root(app).iterdir():
        if not directory.is_dir() or directory.name in active:
            continue
        try:
            metadata = load_job(app, directory.name)
            expired = _created_at(metadata, directory) < cutoff
        except (FileNotFoundError, ValueError, OSError):
            expired = datetime.fromtimestamp(directory.stat().st_mtime, tz=timezone.utc) < cutoff
        if expired:
            shutil.rmtree(directory)
            removed += 1
    return removed


def recover_interrupted_jobs(app: Flask) -> None:
    for directory in _jobs_root(app).iterdir():
        if not directory.is_dir():
            continue
        try:
            metadata = load_job(app, directory.name)
        except (FileNotFoundError, ValueError):
            continue
        if metadata.get("status") == "running":
            outputs = directory / "outputs"
            if outputs.is_dir():
                for name in (*EXPECTED_FORMAL_OUTPUTS, "spss_python_status.json", "Survey_Data_Workbench_完整产出.zip"):
                    (outputs / name).unlink(missing_ok=True)
            metadata.update(
                {
                    "status": "failed",
                    "stage": "interrupted",
                    "message": "上次运行因应用关闭而中断；未报告 SPSS 正式执行成功。",
                    "updatedAt": utc_now().isoformat(timespec="seconds"),
                    "files": output_inventory(outputs) if outputs.is_dir() else [],
                }
            )
            metadata.pop("result", None)
            save_job(app, directory.name, metadata)


def validate_run_config(metadata: dict[str, Any], raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("分析配置必须是 JSON 对象")
    columns = {str(column) for column in metadata.get("columns", [])}
    constructs_raw = raw.get("constructs")
    if not isinstance(constructs_raw, list) or not 1 <= len(constructs_raw) <= 100:
        raise ValueError("请配置 1 至 100 个研究指标")

    constructs: list[dict[str, Any]] = []
    ids: set[str] = set()
    for index, item in enumerate(constructs_raw):
        if not isinstance(item, dict):
            raise ValueError("研究指标配置格式不正确")
        identifier = str(item.get("id") or f"construct_{index + 1}")[:100]
        name = str(item.get("name") or "").strip()[:100]
        label = str(item.get("label") or name).strip()[:240]
        selected = item.get("items")
        if not identifier or identifier in ids or not name:
            raise ValueError("研究指标编号必须唯一，名称不能为空")
        if not isinstance(selected, list) or not selected or len(selected) > 500:
            raise ValueError(f"指标 {name} 必须包含 1 至 500 个题项")
        items = [str(column) for column in selected]
        if len(set(items)) != len(items) or any(column not in columns for column in items):
            raise ValueError(f"指标 {name} 包含重复或不存在的题项")
        ids.add(identifier)
        constructs.append({"id": identifier, "name": name, "label": label, "items": items})

    analyses_raw = raw.get("analyses")
    if not isinstance(analyses_raw, list) or not analyses_raw:
        raise ValueError("请至少选择一种分析方法")
    analyses = [str(item) for item in analyses_raw]
    if len(set(analyses)) != len(analyses) or any(item not in ALLOWED_ANALYSES for item in analyses):
        raise ValueError("分析方法配置无效")
    if "reliability" in analyses and not any(len(item["items"]) >= 2 for item in constructs):
        raise ValueError("信度分析至少需要一个含两个题项的指标")

    models_raw = raw.get("models", []) if "regression" in analyses else []
    if not isinstance(models_raw, list) or len(models_raw) > 100:
        raise ValueError("回归模型配置无效")
    models: list[dict[str, Any]] = []
    for index, model in enumerate(models_raw):
        if not isinstance(model, dict):
            raise ValueError("回归模型配置无效")
        dependent = str(model.get("dependent") or "")
        predictors_raw = model.get("predictors")
        if not isinstance(predictors_raw, list):
            raise ValueError("回归自变量配置无效")
        predictors = [str(item) for item in predictors_raw]
        if dependent not in ids or not predictors or any(item not in ids for item in predictors):
            raise ValueError("回归模型必须引用当前研究指标")
        if dependent in predictors or len(set(predictors)) != len(predictors):
            raise ValueError("回归模型的因变量不能同时作为自变量")
        models.append(
            {
                "name": str(model.get("name") or f"Model {index + 1}")[:120],
                "dependent": dependent,
                "predictors": predictors,
            }
        )
    if "regression" in analyses and not models:
        raise ValueError("多元回归至少需要一个有效模型")

    execute_spss = raw.get("executeSpss", False)
    if not isinstance(execute_spss, bool):
        raise ValueError("SPSS 执行选项无效")
    selected_sheet = raw.get("sheet")
    if selected_sheet is not None and str(selected_sheet) not in metadata.get("sheets", []):
        raise ValueError("工作表选择无效")
    return {
        "sheet": selected_sheet,
        "constructs": constructs,
        "analyses": analyses,
        "models": models,
        "executeSpss": execute_spss,
    }


def create_app(config: dict[str, Any] | None = None) -> Flask:
    app = Flask(__name__, static_folder=str(FRONTEND_DIST), static_url_path="")
    try:
        retention = min(3650, max(1, int(os.environ.get("STATFLOW_RETENTION_DAYS", "30"))))
    except ValueError:
        retention = 30
    data_root = default_data_root()
    app.config.from_mapping(
        # Includes the multipart envelope; the parser independently enforces
        # the exact 100 MB stored-file ceiling and decompression/shape budgets.
        MAX_CONTENT_LENGTH=MAX_DATASET_BYTES + 1024 * 1024,
        DATA_ROOT=data_root,
        JOBS_ROOT=data_root / "jobs",
        RETENTION_DAYS=retention,
        API_TOKEN=os.environ.get("STATFLOW_API_TOKEN", ""),
    )
    if config:
        app.config.update(config)
    app.config["DATA_ROOT"] = Path(app.config["DATA_ROOT"]).expanduser().resolve()
    if config and "DATA_ROOT" in config and "JOBS_ROOT" not in config:
        app.config["JOBS_ROOT"] = app.config["DATA_ROOT"] / "jobs"
    app.config["JOBS_ROOT"] = Path(
        app.config.get("JOBS_ROOT") or app.config["DATA_ROOT"] / "jobs"
    ).expanduser().resolve()
    saved_settings = Path(app.config["DATA_ROOT"]) / "settings.json"
    if saved_settings.is_file() and not (config and "RETENTION_DAYS" in config):
        try:
            saved_days = json.loads(saved_settings.read_text(encoding="utf-8")).get("retentionDays")
            if isinstance(saved_days, int) and not isinstance(saved_days, bool):
                app.config["RETENTION_DAYS"] = saved_days
        except (OSError, json.JSONDecodeError, AttributeError):
            pass
    app.config["RETENTION_DAYS"] = min(3650, max(1, int(app.config["RETENTION_DAYS"])))
    _jobs_root(app).mkdir(parents=True, exist_ok=True)
    app.extensions["state_lock"] = threading.RLock()
    app.extensions["active_jobs"] = set()
    app.extensions["next_retention_purge"] = utc_now() + timedelta(hours=1)
    recover_interrupted_jobs(app)
    purge_expired_jobs(app)

    @app.before_request
    def protect_local_api():
        if not request.path.startswith("/api/"):
            return None
        hostname = (urlsplit(f"//{request.host}").hostname or "").lower()
        if hostname not in LOOPBACK_HOSTS:
            return _error("只允许通过本机回环地址访问", "invalid_host", 400)
        if request.headers.get("Sec-Fetch-Site", "").lower() == "cross-site":
            return _error("已拒绝跨站请求", "cross_site_request", 403)
        origin = request.headers.get("Origin")
        if origin and urlsplit(origin).netloc.lower() != request.host.lower():
            return _error("请求来源与本地服务不匹配", "invalid_origin", 403)
        expected = str(app.config.get("API_TOKEN") or "")
        supplied = request.headers.get("X-StatFlow-Token", "")
        if expected and not secrets.compare_digest(expected, supplied):
            return _error("本地会话令牌无效", "invalid_token", 401)
        now = utc_now()
        if now >= app.extensions["next_retention_purge"]:
            with app.extensions["state_lock"]:
                if now >= app.extensions["next_retention_purge"]:
                    purge_expired_jobs(app)
                    app.extensions["next_retention_purge"] = now + timedelta(hours=1)
        return None

    @app.after_request
    def security_headers(response):
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; base-uri 'none'; connect-src 'self'; frame-ancestors 'none'; "
            "form-action 'self'; img-src 'self' data:; object-src 'none'; script-src 'self'; "
            "style-src 'self' 'unsafe-inline'"
        )
        response.headers["Cross-Origin-Opener-Policy"] = "same-origin"
        response.headers["Cross-Origin-Resource-Policy"] = "same-origin"
        response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["X-Permitted-Cross-Domain-Policies"] = "none"
        if request.path.startswith("/api/") or response.mimetype == "text/html":
            response.headers["Cache-Control"] = "no-store"
        return response

    @app.errorhandler(413)
    def too_large(_: Exception):
        return _error("文件超过 100MB，请先拆分数据", "file_too_large", 413)

    @app.errorhandler(Exception)
    def handle_error(error: Exception):
        if isinstance(error, HTTPException):
            return _error(str(error.description), "http_error", int(error.code or 500))
        if isinstance(error, FileNotFoundError):
            return _error("找不到该任务或文件", "not_found", 404)
        if isinstance(error, ValueError):
            return _error(str(error), "invalid_request", 400)
        app.logger.exception("Unhandled local API error")
        return _error("操作失败；详细信息已写入本地日志", "internal_error", 500)

    @app.get("/api/health")
    def health():
        return jsonify(
            {
                "ok": True,
                "name": "Survey Data Workbench by LAI ZEYU",
                "brand": "Survey Data Workbench by LAI ZEYU",
                "spss": public_spss_status(spss_status()),
                "supportedFormats": sorted(SUPPORTED_EXTENSIONS),
                "retentionDays": app.config["RETENTION_DAYS"],
                "formalOutputPolicy": "format-integrity-only",
                "semanticValidationPolicy": "external-two-authorised-environments",
            }
        )

    @app.get("/api/settings")
    def settings():
        return jsonify(
            {
                "retentionDays": app.config["RETENTION_DAYS"],
                "storageScope": "local_application_data",
                "jobCount": sum(1 for item in _jobs_root(app).iterdir() if item.is_dir()),
            }
        )

    @app.put("/api/settings")
    def update_settings():
        payload = request.get_json(silent=True)
        if (
            not isinstance(payload, dict)
            or not isinstance(payload.get("retentionDays"), int)
            or isinstance(payload.get("retentionDays"), bool)
        ):
            raise ValueError("保留天数必须是 1 至 3650 的整数")
        days = payload["retentionDays"]
        if not 1 <= days <= 3650:
            raise ValueError("保留天数必须是 1 至 3650 的整数")
        with app.extensions["state_lock"]:
            app.config["RETENTION_DAYS"] = days
            settings_path = Path(app.config["DATA_ROOT"]) / "settings.json"
            temporary = settings_path.with_suffix(".json.tmp")
            temporary.write_text(json.dumps({"retentionDays": days}, indent=2), encoding="utf-8")
            temporary.replace(settings_path)
            removed = purge_expired_jobs(app)
            app.extensions["next_retention_purge"] = utc_now() + timedelta(hours=1)
        return jsonify({"retentionDays": days, "removedExpiredJobs": removed})

    @app.post("/api/upload")
    def upload():
        uploaded = request.files.get("file")
        if uploaded is None or not uploaded.filename:
            raise ValueError("请选择一个数据文件")
        suffix = Path(uploaded.filename).suffix.lower()
        if suffix not in SUPPORTED_EXTENSIONS:
            raise ValueError(f"暂不支持 {suffix or '该'} 格式")

        job_id = str(uuid.uuid4())
        directory = job_dir(app, job_id)
        input_dir = directory / "input"
        input_dir.mkdir(parents=True)
        safe_name = secure_filename(uploaded.filename) or f"dataset{suffix}"
        stored = input_dir / f"dataset{suffix}"
        try:
            uploaded.save(stored)
            inspected = inspect_dataset(stored, uploaded.filename)
            metadata = {
                "jobId": job_id,
                "createdAt": utc_now().isoformat(timespec="seconds"),
                "status": "configured",
                "stage": "upload",
                "progress": 0,
                "message": "数据已读取，可以配置分析",
                "safeName": safe_name,
                **inspected,
            }
            save_job(app, job_id, metadata)
        except Exception:
            shutil.rmtree(directory, ignore_errors=True)
            raise
        return jsonify(public_job(metadata))

    @app.post("/api/jobs/<job_id>/sheet")
    def change_sheet(job_id: str):
        with app.extensions["state_lock"]:
            if _uuid(job_id) in app.extensions["active_jobs"]:
                return _error("任务正在运行，不能切换工作表", "job_running", 409)
            metadata = load_job(app, job_id)
            payload = request.get_json(silent=True)
            selected = str(payload.get("sheet") or "") if isinstance(payload, dict) else ""
            if selected not in metadata.get("sheets", []):
                raise ValueError("工作表选择无效")
            inspected = inspect_dataset(Path(metadata["storedPath"]), metadata["fileName"], selected)
            metadata.update(inspected)
            metadata.update({"status": "configured", "message": f"已切换到工作表：{selected}"})
            save_job(app, job_id, metadata)
        return jsonify(public_job(metadata))

    def run_job(job_id: str, config_value: dict[str, Any]) -> None:
        try:
            def update(stage: str, progress: int, message: str) -> None:
                with app.extensions["state_lock"]:
                    current = load_job(app, job_id)
                    current.update(
                        {
                            "status": "running",
                            "stage": stage,
                            "progress": progress,
                            "message": message,
                            "updatedAt": utc_now().isoformat(timespec="seconds"),
                        }
                    )
                    save_job(app, job_id, current)

            result = execute_workflow(job_dir(app, job_id), config_value, update)
            with app.extensions["state_lock"]:
                metadata = load_job(app, job_id)
                spss_result = result.get("spss", {})
                formal_complete = spss_result.get("state") == "complete"
                formal_failed = config_value["executeSpss"] and not formal_complete
                if formal_failed:
                    message = "Python 预检已完成，但 IBM SPSS 正式输出未验证；请查看执行状态。"
                elif formal_complete:
                    message = "Python 预检和 IBM SPSS 正式文件已完成格式完整性解析；发布语义验证仍需两套获授权环境。"
                else:
                    message = "Python 预检、SPSS 语法和下载包已完成；本次未运行 IBM SPSS。"
                metadata.update(
                    {
                        "status": "formal_failed" if formal_failed else "complete",
                        "stage": "formal_failed" if formal_failed else "complete",
                        "progress": 100,
                        "message": message,
                        "result": result,
                        "config": config_value,
                        "completedAt": utc_now().isoformat(timespec="seconds"),
                    }
                )
                save_job(app, job_id, metadata)
        except Exception:
            app.logger.exception("Background analysis failed")
            with app.extensions["state_lock"]:
                try:
                    metadata = load_job(app, job_id)
                    outputs = job_dir(app, job_id) / "outputs"
                    metadata.update(
                        {
                            "status": "failed",
                            "stage": "failed",
                            "message": "分析失败；未报告 IBM SPSS 正式执行成功。",
                            "files": output_inventory(outputs) if outputs.exists() else [],
                        }
                    )
                    save_job(app, job_id, metadata)
                except Exception:
                    app.logger.exception("Could not persist background failure state")
        finally:
            with app.extensions["state_lock"]:
                app.extensions["active_jobs"].discard(job_id)

    @app.post("/api/jobs/<job_id>/run")
    def start_job(job_id: str):
        canonical = _uuid(job_id)
        with app.extensions["state_lock"]:
            metadata = load_job(app, canonical)
            if canonical in app.extensions["active_jobs"] or metadata.get("status") == "running":
                return _error("该任务正在运行", "job_running", 409)
            config_value = validate_run_config(metadata, request.get_json(silent=True))
            if config_value["executeSpss"] and not spss_status().get("installed"):
                return _error(
                    "未检测到用户自行安装的 IBM SPSS Statistics；请关闭正式执行，先生成 Python 预检与语法。",
                    "spss_unavailable",
                    409,
                )
            app.extensions["active_jobs"].add(canonical)
            metadata.update(
                {
                    "status": "running",
                    "stage": "queued",
                    "progress": 3,
                    "message": "任务已进入本地分析队列",
                    "config": config_value,
                }
            )
            save_job(app, canonical, metadata)
            thread = threading.Thread(target=run_job, args=(canonical, config_value), daemon=True)
            try:
                thread.start()
            except Exception:
                app.extensions["active_jobs"].discard(canonical)
                metadata.update({"status": "failed", "stage": "failed", "message": "无法启动本地分析线程。"})
                save_job(app, canonical, metadata)
                raise
        return jsonify(public_job(metadata)), 202

    @app.get("/api/jobs/<job_id>")
    def get_job(job_id: str):
        return jsonify(public_job(load_job(app, job_id)))

    @app.get("/api/jobs/<job_id>/download/<path:filename>")
    def download(job_id: str, filename: str):
        if Path(filename).name in MACHINE_SPECIFIC_OUTPUTS:
            raise FileNotFoundError(filename)
        outputs = (job_dir(app, job_id) / "outputs").resolve()
        target = (outputs / filename).resolve()
        if outputs not in target.parents or not target.is_file():
            raise FileNotFoundError(filename)
        mimetype = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        return send_from_directory(outputs, target.name, as_attachment=True, mimetype=mimetype)

    @app.delete("/api/jobs/<job_id>")
    def delete_job(job_id: str):
        canonical = _uuid(job_id)
        with app.extensions["state_lock"]:
            if canonical in app.extensions["active_jobs"]:
                return _error("任务正在运行，暂不能删除", "job_running", 409)
            directory = job_dir(app, canonical)
            if not directory.is_dir():
                raise FileNotFoundError(canonical)
            shutil.rmtree(directory)
        return "", 204

    @app.delete("/api/data")
    def delete_all_data():
        with app.extensions["state_lock"]:
            if app.extensions["active_jobs"]:
                return _error("有任务正在运行，暂不能清空数据", "jobs_running", 409)
            root = _jobs_root(app)
            shutil.rmtree(root)
            root.mkdir(parents=True)
        return "", 204

    @app.get("/favicon.ico")
    def favicon():
        return "", 204

    @app.get("/")
    @app.get("/<path:path>")
    def frontend(path: str = ""):
        if path and (FRONTEND_DIST / path).is_file():
            return send_from_directory(FRONTEND_DIST, path)
        if not (FRONTEND_DIST / "index.html").is_file():
            return "前端尚未构建，请先运行前端构建。", 503
        return send_from_directory(FRONTEND_DIST, "index.html")

    return app


if __name__ == "__main__":
    from server import main

    main()
