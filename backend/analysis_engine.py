from __future__ import annotations

import csv
import json
import math
import re
import shutil
import zipfile
import zlib
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

import numpy as np
import pandas as pd

from spss_runner import EXPECTED_FORMAL_OUTPUTS, run_spss_automatically


SUPPORTED_EXTENSIONS = {".xlsx", ".xls", ".xlsm", ".csv", ".tsv", ".txt", ".sav", ".zsav", ".por"}
MAX_DATASET_BYTES = 100 * 1024 * 1024
MAX_DATASET_ROWS = 1_000_000
MAX_DATASET_COLUMNS = 2_000
MAX_DATASET_CELLS = 20_000_000
MAX_DATASET_MEMORY_BYTES = 1024 * 1024 * 1024
MAX_EXCEL_ARCHIVE_ENTRIES = 20_000
MAX_EXCEL_UNCOMPRESSED_BYTES = 512 * 1024 * 1024
MAX_EXCEL_ENTRY_BYTES = 256 * 1024 * 1024
MAX_EXCEL_COMPRESSION_RATIO = 200
MAX_BUNDLE_ENTRIES = 128
MAX_BUNDLE_FILE_BYTES = 512 * 1024 * 1024
MAX_BUNDLE_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
ITEM_PATTERN = re.compile(r"^\s*([A-Za-z][A-Za-z_]{0,15}?)[\s_-]*(\d{1,3})(?=\b|[.\s:_-])")
SPSS_RESERVED_WORDS = {
    "ALL",
    "AND",
    "BY",
    "EQ",
    "GE",
    "GT",
    "LE",
    "LT",
    "NE",
    "NOT",
    "OR",
    "TO",
    "WITH",
}
MACHINE_SPECIFIC_OUTPUTS = {
    "run_with_spss_external.py",
    "run_with_spss_python.sps",
    "run_spss_windows.cmd",
    "spss_python_status.json",
}
PORTABLE_STATUS_LITERAL_TOKEN = "__SPSS_STATUS_PATH_JSON__"
PORTABLE_COMMAND_PATH_TOKEN = "__SPSS_OUTPUT_DIR_COMMAND_JSON__"


def json_dump(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def safe_float(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _validate_regular_dataset_file(path: Path) -> None:
    if not path.is_file() or path.is_symlink():
        raise ValueError("数据文件必须是普通文件")
    size = path.stat().st_size
    if size <= 0:
        raise ValueError("数据文件为空")
    if size > MAX_DATASET_BYTES:
        raise ValueError("数据文件超过 100MB，请先拆分数据")


def _preflight_excel_archive(path: Path) -> None:
    if path.suffix.lower() not in {".xlsx", ".xlsm"}:
        return
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            if not entries or len(entries) > MAX_EXCEL_ARCHIVE_ENTRIES:
                raise ValueError("Excel 压缩包的文件数量超出安全范围")
            total = 0
            seen: set[str] = set()
            for entry in entries:
                name = entry.filename.replace("\\", "/")
                parts = name.rstrip("/").split("/")
                if (
                    not name
                    or name.startswith("/")
                    or any(part in {"", ".", ".."} for part in parts)
                    or name.casefold() in seen
                    or entry.flag_bits & 0x1
                ):
                    raise ValueError("Excel 压缩包包含不安全、重复或加密的条目")
                seen.add(name.casefold())
                if entry.file_size < 0 or entry.file_size > MAX_EXCEL_ENTRY_BYTES:
                    raise ValueError("Excel 压缩包包含过大的单个条目")
                total += entry.file_size
                if total > MAX_EXCEL_UNCOMPRESSED_BYTES:
                    raise ValueError("Excel 解压后的总大小超过 512MB 安全上限")
                if entry.file_size and entry.compress_size == 0:
                    raise ValueError("Excel 压缩包包含异常零长度压缩数据")
                if entry.compress_size and entry.file_size / entry.compress_size > MAX_EXCEL_COMPRESSION_RATIO:
                    raise ValueError("Excel 压缩比异常，拒绝可能的压缩炸弹")
            corrupt = archive.testzip()
            if corrupt is not None:
                raise ValueError(f"Excel 压缩包包含损坏条目：{corrupt}")
    except (zipfile.BadZipFile, OSError, RuntimeError, zlib.error) as exc:
        raise ValueError("Excel 文件不是有效的 Office 压缩包") from exc


def _validate_dataset_shape(frame: pd.DataFrame) -> pd.DataFrame:
    rows, columns = frame.shape
    if rows > MAX_DATASET_ROWS:
        raise ValueError(f"数据超过 {MAX_DATASET_ROWS:,} 行安全上限")
    if columns <= 0 or columns > MAX_DATASET_COLUMNS:
        raise ValueError(f"数据列数必须介于 1 和 {MAX_DATASET_COLUMNS:,} 之间")
    if rows * columns > MAX_DATASET_CELLS:
        raise ValueError(f"数据单元格总数超过 {MAX_DATASET_CELLS:,} 安全上限")
    memory_usage = getattr(frame, "memory_usage", None)
    if callable(memory_usage):
        memory_bytes = int(memory_usage(index=True, deep=True).sum())
        if memory_bytes > MAX_DATASET_MEMORY_BYTES:
            raise ValueError("数据解析后内存占用超过 1GB 安全上限")
    return frame


def _bounded_row_read_limit(column_count: int) -> int:
    if column_count <= 0 or column_count > MAX_DATASET_COLUMNS:
        raise ValueError(f"数据列数必须介于 1 和 {MAX_DATASET_COLUMNS:,} 之间")
    return min(MAX_DATASET_ROWS, MAX_DATASET_CELLS // column_count) + 1


def _normalized_column_names(columns: list[Any] | tuple[Any, ...]) -> list[str]:
    normalized: list[str] = []
    for index, column in enumerate(columns):
        missing = column is None
        if not missing:
            try:
                missing = bool(pd.isna(column))
            except (TypeError, ValueError):
                missing = False
        text = "" if missing else str(column).strip()
        normalized.append(text or f"Column_{index + 1}")
    seen: dict[str, str] = {}
    collisions: list[str] = []
    for column in normalized:
        key = column.casefold()
        if key in seen:
            collisions.append(f"{seen[key]!r} / {column!r}")
        else:
            seen[key] = column
    if collisions:
        raise ValueError("列名在去除空格或忽略大小写后发生冲突：" + ", ".join(collisions[:5]))
    return normalized


def normalize_dataset_columns(frame: pd.DataFrame) -> pd.DataFrame:
    normalized = _normalized_column_names(list(frame.columns))
    frame.columns = normalized
    return frame


def _read_delimited(path: Path) -> pd.DataFrame:
    encodings = ["utf-8-sig", "utf-8", "gb18030", "latin-1"]
    separator = "\t" if path.suffix.lower() == ".tsv" else None
    last_error: Exception | None = None
    for encoding in encodings:
        try:
            # Read the literal first row without treating it as a header.
            # Pandas otherwise silently rewrites exact duplicate names (for
            # example A/A to A/A.1), bypassing the collision policy.
            raw_header = pd.read_csv(
                path,
                sep=separator,
                engine="python",
                encoding=encoding,
                header=None,
                nrows=1,
            )
            if raw_header.empty:
                raise ValueError("文本数据缺少列名行")
            column_names = _normalized_column_names(list(raw_header.iloc[0]))
        except Exception as exc:  # pragma: no cover - depends on uploaded encodings
            last_error = exc
            continue
        _validate_dataset_shape(pd.DataFrame(columns=column_names))
        try:
            frame = pd.read_csv(
                path,
                sep=separator,
                engine="python",
                encoding=encoding,
                nrows=_bounded_row_read_limit(len(column_names)),
            )
        except Exception as exc:  # pragma: no cover - depends on uploaded encodings
            last_error = exc
            continue
        if len(frame.columns) != len(column_names):
            raise ValueError("文本数据的表头列数与解析结果不一致")
        frame.columns = column_names
        return _validate_dataset_shape(frame)
    raise ValueError(f"无法读取文本数据：{last_error}")


def read_dataset(path: Path, sheet: str | None = None) -> tuple[pd.DataFrame, list[str], str | None]:
    _validate_regular_dataset_file(path)
    suffix = path.suffix.lower()
    if suffix not in SUPPORTED_EXTENSIONS:
        raise ValueError(f"暂不支持 {suffix or '未知'} 格式")

    if suffix in {".xlsx", ".xls", ".xlsm"}:
        _preflight_excel_archive(path)
        with pd.ExcelFile(path) as excel:
            sheets = [str(name) for name in excel.sheet_names]
        if not sheets or len(sheets) > 1_000:
            raise ValueError("Excel 工作表数量超出安全范围")
        selected = sheet if sheet in sheets else sheets[0]
        raw_header = pd.read_excel(path, sheet_name=selected, header=None, nrows=1)
        if raw_header.empty:
            raise ValueError("Excel 工作表缺少列名行")
        column_names = _normalized_column_names(list(raw_header.iloc[0]))
        _validate_dataset_shape(pd.DataFrame(columns=column_names))
        frame = pd.read_excel(
            path,
            sheet_name=selected,
            nrows=_bounded_row_read_limit(len(column_names)),
        )
        if len(frame.columns) != len(column_names):
            raise ValueError("Excel 工作表的表头列数与解析结果不一致")
        frame.columns = column_names
        return _validate_dataset_shape(frame), sheets, selected

    if suffix in {".csv", ".tsv", ".txt"}:
        return _read_delimited(path), [], None

    try:
        import pyreadstat
    except ImportError as exc:  # pragma: no cover - dependency is installed by launcher
        raise ValueError("读取 SAV/POR 需要 pyreadstat，请运行启动脚本安装依赖") from exc

    reader = pyreadstat.read_sav if suffix in {".sav", ".zsav"} else pyreadstat.read_por
    declared_columns = 0
    try:
        _, metadata = reader(str(path), metadataonly=True)
        declared_rows = int(metadata.number_rows or 0)
        declared_columns = len(metadata.column_names or [])
        if declared_rows < 0 or declared_rows > MAX_DATASET_ROWS or not 1 <= declared_columns <= MAX_DATASET_COLUMNS:
            raise ValueError("SPSS 数据的声明行列数超出安全范围")
        if declared_rows and declared_columns and declared_rows * declared_columns > MAX_DATASET_CELLS:
            raise ValueError("SPSS 数据的声明单元格总数超出安全范围")
        _normalized_column_names(list(metadata.column_names or []))
    except TypeError as exc:
        # The pinned reader exposes metadata-only parsing. Silently falling back
        # without a declared column count would make the cell/memory budget
        # unenforceable before allocation, so unsupported legacy variants fail
        # closed instead of being partially or unboundedly read.
        raise ValueError("当前读取器无法在安全解析前获取 SPSS 数据行列元数据") from exc
    bounded_rows = _bounded_row_read_limit(declared_columns)
    frame, _ = reader(str(path), row_limit=bounded_rows)
    return _validate_dataset_shape(frame), [], None


def _item_code(column: str) -> tuple[str, int] | None:
    match = ITEM_PATTERN.match(str(column))
    if not match:
        return None
    return match.group(1).upper(), int(match.group(2))


def _numeric_ratio(series: pd.Series) -> float:
    if pd.api.types.is_numeric_dtype(series):
        return 1.0
    nonempty = series.dropna()
    if nonempty.empty:
        return 0.0
    return float(pd.to_numeric(nonempty, errors="coerce").notna().mean())


def detect_constructs(frame: pd.DataFrame) -> list[dict[str, Any]]:
    groups: dict[str, list[tuple[int, str]]] = {}
    for column in frame.columns:
        parsed = _item_code(str(column))
        if parsed is None or _numeric_ratio(frame[column]) < 0.6:
            continue
        prefix, index = parsed
        groups.setdefault(prefix, []).append((index, str(column)))

    constructs = []
    for prefix, values in sorted(groups.items()):
        ordered = [column for _, column in sorted(values)]
        if len(ordered) < 2:
            continue
        constructs.append(
            {
                "id": f"auto_{prefix.lower()}",
                "name": prefix,
                "label": prefix,
                "items": ordered,
                "detected": True,
            }
        )
    return constructs


def tam_models(constructs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    ids = {construct["name"].upper(): construct["id"] for construct in constructs}
    required = {"FQ", "EV", "ECON", "SBI", "ECO", "PU", "PEOU", "ATT", "MPO"}
    if not required.issubset(ids):
        return []
    return [
        {"name": "H1：PEOU = FQ", "dependent": ids["PEOU"], "predictors": [ids["FQ"]]},
        {
            "name": "H2/H3/H5/H6/H7：PU 模型",
            "dependent": ids["PU"],
            "predictors": [ids[key] for key in ["FQ", "EV", "SBI", "ECO", "PEOU"]],
        },
        {
            "name": "H8/H9：ATT 模型",
            "dependent": ids["ATT"],
            "predictors": [ids["PEOU"], ids["PU"]],
        },
        {
            "name": "H4/H10：MPO 模型",
            "dependent": ids["MPO"],
            "predictors": [ids["ECON"], ids["ATT"]],
        },
    ]


def inspect_dataset(path: Path, original_name: str, sheet: str | None = None) -> dict[str, Any]:
    frame, sheets, selected_sheet = read_dataset(path, sheet)
    normalize_dataset_columns(frame)
    numeric_columns = [str(column) for column in frame.columns if _numeric_ratio(frame[column]) >= 0.6]
    constructs = detect_constructs(frame)
    preview = frame.head(5).replace({np.nan: None}).astype(object)
    preview_rows = [
        {str(key): (None if pd.isna(value) else str(value)) for key, value in row.items()}
        for row in preview.to_dict(orient="records")
    ]
    return {
        "fileName": original_name,
        "storedPath": str(path),
        "fileType": path.suffix.lower().lstrip(".").upper(),
        "rows": int(len(frame)),
        "columns": [str(column) for column in frame.columns],
        "numericColumns": numeric_columns,
        "columnCount": int(len(frame.columns)),
        "sheets": sheets,
        "selectedSheet": selected_sheet,
        "preview": preview_rows,
        "detectedConstructs": constructs,
        "suggestedModels": tam_models(constructs),
    }


def sanitize_spss_name(value: str, used: set[str], fallback: str = "V") -> str:
    parsed = _item_code(value)
    base = f"{parsed[0]}{parsed[1]}" if parsed else re.sub(r"[^A-Za-z0-9_]", "_", value.strip())
    base = re.sub(r"_+", "_", base).strip("_") or fallback
    if not base[0].isalpha() and base[0] not in {"@", "#", "$"}:
        base = f"{fallback}_{base}"
    if base.upper() in SPSS_RESERVED_WORDS:
        base = f"{fallback}_{base}"
    base = base[:56]
    candidate = base
    counter = 2
    while candidate.upper() in used:
        candidate = f"{base[:52]}_{counter}"
        counter += 1
    used.add(candidate.upper())
    return candidate


def _spss_quote(value: str) -> str:
    # Labels are emitted inside both single- and double-quoted SPSS literals.
    # Remove control characters and convert ASCII quotes so an uploaded label
    # cannot terminate either literal and inject command syntax.
    cleaned = re.sub(r"[\x00-\x1f\x7f]+", " ", value)
    return cleaned.replace('"', "“").replace("'", "’")[:240]


def _spss_path(value: Path) -> str:
    """Return a quoted-literal-safe, cross-platform SPSS file path."""

    return str(value.resolve()).replace("\\", "/").replace("'", "''")


def build_portable_spss_template(
    syntax: str,
    *,
    status_literal: str,
    spss_output_path: str,
    forbidden_paths: set[str],
) -> str:
    """Replace machine paths with tokens for their two parser contexts."""

    if status_literal not in syntax or spss_output_path not in syntax:
        raise ValueError("Could not locate every machine-specific SPSS path in generated syntax")
    portable = syntax.replace(status_literal, PORTABLE_STATUS_LITERAL_TOKEN)
    portable = portable.replace(spss_output_path, PORTABLE_COMMAND_PATH_TOKEN)
    for original in forbidden_paths:
        if original and original in portable:
            raise ValueError("Portable SPSS template still contains a machine-specific path")
        escaped = json.dumps(original, ensure_ascii=False)[1:-1] if original else ""
        if escaped and escaped in portable:
            raise ValueError("Portable SPSS template still contains a JSON-escaped machine path")
    return portable


def prepare_data(
    frame: pd.DataFrame, constructs: list[dict[str, Any]], output_dir: Path
) -> tuple[pd.DataFrame, pd.DataFrame, list[dict[str, Any]], dict[str, str]]:
    _validate_dataset_shape(frame)
    normalize_dataset_columns(frame)
    used: set[str] = set()
    mapping: dict[str, str] = {}
    for column in frame.columns:
        mapping[str(column)] = sanitize_spss_name(str(column), used)

    prepared = frame.rename(columns=mapping).copy()
    clean_constructs: list[dict[str, Any]] = []
    analysis_originals: set[str] = set()
    for index, construct in enumerate(constructs):
        items = [str(item) for item in construct.get("items", []) if str(item) in mapping]
        if not items:
            continue
        analysis_originals.update(items)
        composite = sanitize_spss_name(str(construct.get("name") or f"Scale_{index + 1}"), used, "SCALE")
        clean_constructs.append(
            {
                "id": str(construct.get("id") or f"construct_{index + 1}"),
                "name": str(construct.get("name") or composite),
                "label": str(construct.get("label") or construct.get("name") or composite),
                "itemsOriginal": items,
                "items": [mapping[item] for item in items],
                "composite": composite,
            }
        )

    for original in analysis_originals:
        prepared[mapping[original]] = pd.to_numeric(prepared[mapping[original]], errors="coerce")

    variable_map = pd.DataFrame(
        [{"original_column": original, "spss_variable": renamed} for original, renamed in mapping.items()]
    )
    prepared_path = output_dir / "prepared_data.csv"
    prepared.to_csv(prepared_path, index=False, quoting=csv.QUOTE_MINIMAL)
    variable_map.to_csv(output_dir / "01_variable_map.csv", index=False)
    return prepared, variable_map, clean_constructs, mapping


def cronbach_alpha(items: pd.DataFrame) -> float:
    clean = items.dropna()
    k = clean.shape[1]
    if k < 2 or len(clean) < 2:
        return float("nan")
    total_variance = clean.sum(axis=1).var(ddof=1)
    if total_variance == 0:
        return float("nan")
    return float(k / (k - 1) * (1 - clean.var(axis=0, ddof=1).sum() / total_variance))


def corrected_item_total(items: pd.DataFrame, item: str) -> float:
    clean = items.dropna()
    others = clean.drop(columns=[item]).sum(axis=1)
    if len(clean) < 3 or clean[item].std(ddof=1) == 0 or others.std(ddof=1) == 0:
        return float("nan")
    return float(np.corrcoef(clean[item], others)[0, 1])


def kmo_statistic(correlation: np.ndarray) -> float:
    if (
        correlation.ndim != 2
        or correlation.shape[0] != correlation.shape[1]
        or not np.isfinite(correlation).all()
    ):
        return float("nan")
    # NumPy 2.0 may emit low-level matmul warnings while computing a valid
    # pseudoinverse on highly correlated survey items. Validate the result
    # explicitly instead of leaking those implementation warnings to users.
    with np.errstate(divide="ignore", over="ignore", invalid="ignore"):
        inverse = np.linalg.pinv(correlation)
    if not np.isfinite(inverse).all():
        return float("nan")
    with np.errstate(divide="ignore", over="ignore", invalid="ignore"):
        scale = np.sqrt(np.outer(np.diag(inverse), np.diag(inverse)))
        partial = -inverse / scale
    if not np.isfinite(partial).all():
        return float("nan")
    np.fill_diagonal(partial, 0)
    corr_sq = correlation**2
    partial_sq = partial**2
    np.fill_diagonal(corr_sq, 0)
    denominator = corr_sq.sum() + partial_sq.sum()
    return float(corr_sq.sum() / denominator) if denominator else float("nan")


def chi2_sf_approx(value: float, degrees: int) -> float:
    if value <= 0 or degrees <= 0:
        return 1.0
    z = ((value / degrees) ** (1 / 3) - (1 - 2 / (9 * degrees))) / math.sqrt(2 / (9 * degrees))
    return 0.5 * math.erfc(z / math.sqrt(2))


def ols_preview(frame: pd.DataFrame, dependent: str, predictors: list[str], name: str) -> dict[str, Any]:
    clean = frame[[dependent, *predictors]].dropna().astype(float)
    if len(clean) <= len(predictors) + 2:
        return {"model": name, "error": "有效样本不足", "rows": []}
    y = clean[dependent].to_numpy()
    x = clean[predictors].to_numpy()
    design = np.column_stack([np.ones(len(clean)), x])
    beta = np.linalg.pinv(design.T @ design) @ design.T @ y
    residual = y - design @ beta
    degrees = len(clean) - design.shape[1]
    mse = float(residual @ residual / degrees)
    standard_errors = np.sqrt(np.diag(np.linalg.pinv(design.T @ design)) * mse)
    t_values = beta / standard_errors
    total = float(((y - y.mean()) ** 2).sum())
    r2 = 1 - float((residual**2).sum()) / total if total else float("nan")
    rows = []
    for index, term in enumerate(["Intercept", *predictors]):
        standardized = None
        if index:
            y_sd = clean[dependent].std(ddof=1)
            x_sd = clean[term].std(ddof=1)
            standardized = float(beta[index] * x_sd / y_sd) if y_sd else None
        rows.append(
            {
                "term": term,
                "b": safe_float(beta[index]),
                "se": safe_float(standard_errors[index]),
                "t": safe_float(t_values[index]),
                "pApprox": safe_float(math.erfc(abs(float(t_values[index])) / math.sqrt(2))),
                "standardizedBeta": safe_float(standardized),
            }
        )
    adjusted = 1 - (1 - r2) * (len(clean) - 1) / degrees
    return {
        "model": name,
        "n": int(len(clean)),
        "r2": safe_float(r2),
        "adjustedR2": safe_float(adjusted),
        "rows": rows,
    }


def build_python_preview(
    prepared: pd.DataFrame,
    constructs: list[dict[str, Any]],
    models: list[dict[str, Any]],
    output_dir: Path,
) -> dict[str, Any]:
    scored = prepared.copy()
    id_to_construct = {construct["id"]: construct for construct in constructs}
    descriptives: list[dict[str, Any]] = []
    reliability: list[dict[str, Any]] = []
    item_total_rows: list[dict[str, Any]] = []

    for construct in constructs:
        items = construct["items"]
        numeric = scored[items].apply(pd.to_numeric, errors="coerce")
        scored[construct["composite"]] = numeric.mean(axis=1)
        score = scored[construct["composite"]]
        descriptives.append(
            {
                "construct": construct["name"],
                "variable": construct["composite"],
                "items": len(items),
                "n": int(score.notna().sum()),
                "mean": safe_float(score.mean()),
                "sd": safe_float(score.std(ddof=1)),
                "min": safe_float(score.min()),
                "max": safe_float(score.max()),
            }
        )
        alpha = cronbach_alpha(numeric)
        reliability.append(
            {
                "construct": construct["name"],
                "items": len(items),
                "n": int(numeric.dropna().shape[0]),
                "cronbachAlpha": safe_float(alpha),
                "interpretation": (
                    "可接受" if math.isfinite(alpha) and alpha >= 0.7 else "偏低，需谨慎解释"
                ),
            }
        )
        if len(items) >= 2:
            for item in items:
                item_total_rows.append(
                    {
                        "construct": construct["name"],
                        "item": item,
                        "correctedItemTotal": safe_float(corrected_item_total(numeric, item)),
                    }
                )

    pd.DataFrame(descriptives).to_csv(output_dir / "02_construct_descriptives.csv", index=False)
    pd.DataFrame(reliability).to_csv(output_dir / "03_reliability_preview.csv", index=False)
    pd.DataFrame(item_total_rows).to_csv(output_dir / "04_item_total_preview.csv", index=False)

    composites = [construct["composite"] for construct in constructs]
    correlations = scored[composites].corr() if composites else pd.DataFrame()
    correlations.to_csv(output_dir / "05_correlations_preview.csv")

    item_columns = [item for construct in constructs for item in construct["items"]]
    factor_check: dict[str, Any] = {"kmo": None, "bartlettChiSquare": None, "bartlettDf": None, "bartlettPApprox": None}
    if len(item_columns) >= 3:
        item_frame = scored[item_columns].dropna().astype(float)
        if len(item_frame) >= 3:
            correlation = item_frame.corr().to_numpy()
            eigenvalues = np.linalg.eigvalsh(correlation)
            eigenvalues = np.sort(eigenvalues)[::-1]
            log_det = float(np.log(np.clip(eigenvalues, 1e-300, None)).sum())
            sample_size, variable_count = item_frame.shape
            chi_square = -(sample_size - 1 - (2 * variable_count + 5) / 6) * log_det
            degrees = variable_count * (variable_count - 1) // 2
            factor_check = {
                "kmo": safe_float(kmo_statistic(correlation)),
                "bartlettChiSquare": safe_float(chi_square),
                "bartlettDf": int(degrees),
                "bartlettPApprox": safe_float(chi2_sf_approx(chi_square, degrees)),
                "eigenvalues": [safe_float(value) for value in eigenvalues],
                "factorsAboveOne": int((eigenvalues > 1).sum()),
            }
    pd.DataFrame([factor_check]).to_csv(output_dir / "06_factorability_preview.csv", index=False)

    regression_results: list[dict[str, Any]] = []
    regression_rows: list[dict[str, Any]] = []
    for index, model in enumerate(models):
        dependent_construct = id_to_construct.get(str(model.get("dependent")))
        predictor_constructs = [
            id_to_construct[predictor]
            for predictor in model.get("predictors", [])
            if predictor in id_to_construct
        ]
        if dependent_construct is None or not predictor_constructs:
            continue
        result = ols_preview(
            scored,
            dependent_construct["composite"],
            [construct["composite"] for construct in predictor_constructs],
            str(model.get("name") or f"Model {index + 1}"),
        )
        regression_results.append(result)
        for row in result.get("rows", []):
            regression_rows.append({"model": result["model"], **row, "n": result.get("n"), "r2": result.get("r2")})
    pd.DataFrame(regression_rows).to_csv(output_dir / "07_regression_preview.csv", index=False)

    warnings: list[str] = []
    low_alpha = [row["construct"] for row in reliability if (row["cronbachAlpha"] or -1) < 0.7]
    if low_alpha:
        warnings.append("以下构念的 Cronbach's alpha 低于 .70：" + "、".join(low_alpha))
    if factor_check.get("kmo") is not None and factor_check["kmo"] < 0.6:
        warnings.append("KMO 低于 .60，探索性因子分析结果需要谨慎解释。")
    if not warnings:
        warnings.append("Python 预检未发现自动阈值警告；最终判断请以 SPSS 输出为准。")

    report = {
        "generatedAt": datetime.now().isoformat(timespec="seconds"),
        "mode": "Python 预检（不是 IBM SPSS 正式输出）",
        "rows": int(len(prepared)),
        "constructs": len(constructs),
        "descriptives": descriptives,
        "reliability": reliability,
        "factorability": factor_check,
        "regressions": regression_results,
        "warnings": warnings,
    }
    json_dump(output_dir / "analysis_summary.json", report)

    lines = [
        "# 自动分析摘要",
        "",
        "> 本文件是 Python 预检摘要，不是 IBM SPSS 正式输出。若请求正式执行，请仅使用已通过完成标记与文件完整性验证的 `.spv` / `.pdf`。",
        "",
        f"- 有效导入行数：{len(prepared)}",
        f"- 已配置构念：{len(constructs)}",
        f"- 已配置回归模型：{len(regression_results)}",
        "",
        "## 信度预检",
        "",
        "| 构念 | 题项数 | Cronbach's alpha | 自动提示 |",
        "|---|---:|---:|---|",
    ]
    for row in reliability:
        alpha_text = "" if row["cronbachAlpha"] is None else f"{row['cronbachAlpha']:.3f}"
        lines.append(f"| {row['construct']} | {row['items']} | {alpha_text} | {row['interpretation']} |")
    lines.extend(["", "## 因子适用性预检", ""])
    kmo_text = "无法计算" if factor_check.get("kmo") is None else f"{factor_check['kmo']:.3f}"
    lines.append(f"- KMO：{kmo_text}")
    if factor_check.get("bartlettPApprox") is not None:
        lines.append(f"- Bartlett p（近似）：{factor_check['bartlettPApprox']:.6f}")
    lines.extend(["", "## 自动警告", ""])
    lines.extend([f"- {warning}" for warning in warnings])
    (output_dir / "analysis_summary_cn.md").write_text("\n".join(lines), encoding="utf-8")
    return report


def _variable_specs(frame: pd.DataFrame) -> str:
    specs = []
    for column in frame.columns:
        series = frame[column]
        if pd.api.types.is_numeric_dtype(series):
            specs.append(f"  {column} F16.6")
        else:
            lengths = series.dropna().astype(str).str.len()
            width = 32 if lengths.empty else max(16, min(1024, int(lengths.max()) + 8))
            specs.append(f"  {column} A{width}")
    return "\n".join(specs)


def _resolve_models(models: list[dict[str, Any]], constructs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    lookup = {construct["id"]: construct for construct in constructs}
    resolved = []
    for index, model in enumerate(models):
        dependent = lookup.get(str(model.get("dependent")))
        predictors = [lookup[item] for item in model.get("predictors", []) if item in lookup]
        if dependent and predictors:
            resolved.append(
                {
                    "name": str(model.get("name") or f"Model {index + 1}"),
                    "dependent": dependent["composite"],
                    "predictors": [item["composite"] for item in predictors],
                }
            )
    return resolved


def generate_spss_python_driver(
    prepared: pd.DataFrame,
    constructs: list[dict[str, Any]],
    models: list[dict[str, Any]],
    analyses: list[str],
    output_dir: Path,
) -> Path:
    csv_path = output_dir / "prepared_data.csv"
    sav_path = output_dir / "analysis_data.sav"
    spv_path = output_dir / "analysis_output.spv"
    pdf_path = output_dir / "analysis_output.pdf"
    marker_path = output_dir / "spss_python_status.json"
    syntax_path = output_dir / "run_with_spss_python.sps"
    all_items = [item for construct in constructs for item in construct["items"]]
    composites = [construct["composite"] for construct in constructs]
    resolved_models = _resolve_models(models, constructs)
    commands: list[str] = [
        "SET UNICODE=ON.",
        "SET DECIMAL=DOT.",
        "OUTPUT NEW NAME=AutoSPSS.",
        "",
        "GET DATA",
        "  /TYPE=TXT",
        f"  /FILE='{_spss_path(csv_path)}'",
        "  /ENCODING='UTF8'",
        "  /DELCASE=LINE",
        '  /DELIMITERS=","',
        "  /QUALIFIER='\"'",
        "  /ARRANGEMENT=DELIMITED",
        "  /FIRSTCASE=2",
        "  /VARIABLES=",
        _variable_specs(prepared),
        ".",
        "CACHE.",
        "EXECUTE.",
        "",
    ]

    for construct in constructs:
        minimum = 2 if len(construct["items"]) >= 2 else 1
        commands.extend(
            [
                f"COMPUTE {construct['composite']}=MEAN.{minimum}({','.join(construct['items'])}).",
                f'VARIABLE LABELS {construct["composite"]} "{_spss_quote(construct["label"])} composite mean".',
            ]
        )
    commands.extend(["EXECUTE.", f"SAVE OUTFILE='{_spss_path(sav_path)}' /COMPRESSED.", ""])

    if "descriptives" in analyses and (all_items or composites):
        commands.extend(
            [
                f"DESCRIPTIVES VARIABLES={' '.join([*all_items, *composites])}",
                "  /STATISTICS=MEAN STDDEV MIN MAX.",
                "",
            ]
        )
    if "reliability" in analyses:
        for construct in constructs:
            if len(construct["items"]) < 2:
                continue
            commands.extend(
                [
                    "RELIABILITY",
                    f"  /VARIABLES={' '.join(construct['items'])}",
                    f"  /SCALE('{_spss_quote(construct['label'])}') ALL",
                    "  /MODEL=ALPHA",
                    "  /STATISTICS=DESCRIPTIVE SCALE CORR",
                    "  /SUMMARY=TOTAL.",
                    "",
                ]
            )
    if "correlations" in analyses and len(composites) >= 2:
        commands.extend(
            [
                "CORRELATIONS",
                f"  /VARIABLES={' '.join(composites)}",
                "  /PRINT=TWOTAIL SIG",
                "  /MISSING=PAIRWISE.",
                "",
            ]
        )
    if "factor" in analyses and len(all_items) >= 3:
        factor_count = max(1, min(len(constructs), len(all_items) - 1))
        commands.extend(
            [
                "FACTOR",
                f"  /VARIABLES {' '.join(all_items)}",
                "  /MISSING LISTWISE",
                f"  /ANALYSIS {' '.join(all_items)}",
                "  /PRINT INITIAL KMO EXTRACTION ROTATION",
                "  /FORMAT SORT BLANK(.30)",
                "  /PLOT EIGEN",
                f"  /CRITERIA FACTORS({factor_count}) ITERATE(25)",
                "  /EXTRACTION PAF",
                "  /ROTATION PROMAX.",
                "",
            ]
        )
    if "regression" in analyses:
        for model in resolved_models:
            commands.extend(
                [
                    "REGRESSION",
                    "  /MISSING LISTWISE",
                    "  /STATISTICS COEFF OUTS R ANOVA COLLIN TOL CI(95)",
                    f"  /DEPENDENT {model['dependent']}",
                    f"  /METHOD=ENTER {' '.join(model['predictors'])}.",
                    "",
                ]
            )

    commands.extend(
        [
            f"OUTPUT SAVE OUTFILE='{_spss_path(spv_path)}'.",
            "OUTPUT EXPORT",
            "  /CONTENTS EXPORT=VISIBLE LAYERS=PRINTSETTING MODELVIEWS=PRINTSETTING",
            f"  /PDF DOCUMENTFILE='{_spss_path(pdf_path)}'.",
        ]
    )
    submitted_commands = "\n".join(commands)
    metadata = {
        "engine": "IBM SPSS Statistics embedded Python",
        "api": "spss.Submit",
        "analyses": analyses,
        "constructCount": len(constructs),
        "modelCount": len(resolved_models),
    }
    # `status_path` is consumed by Python's `open()`, not by the SPSS syntax
    # parser.  In particular, do not use `_spss_path()` here: SPSS escapes an
    # apostrophe by doubling it, while that transformation would point Python
    # at a different file for valid paths such as `O'Brien`.
    status_literal = json.dumps(str(marker_path.resolve()), ensure_ascii=False)
    commands_literal = json.dumps(submitted_commands, ensure_ascii=False)
    metadata_json_literal = json.dumps(json.dumps(metadata, ensure_ascii=False), ensure_ascii=False)
    syntax = f"""* Generated automatically by Survey Data Workbench by LAI ZEYU.
* All analysis commands below are submitted by SPSS embedded Python.
BEGIN PROGRAM Python3.
import datetime
import json
import traceback
import spss

status_path = {status_literal}
metadata = json.loads({metadata_json_literal})
commands = {commands_literal}
try:
    spss.Submit(commands)
    metadata["status"] = "complete"
    metadata["completedAt"] = datetime.datetime.now().isoformat(timespec="seconds")
except Exception as exc:
    metadata["status"] = "failed"
    metadata["error"] = str(exc)
    metadata["traceback"] = traceback.format_exc()
    raise
finally:
    with open(status_path, "w", encoding="utf-8") as handle:
        json.dump(metadata, handle, ensure_ascii=False, indent=2)
END PROGRAM.
"""
    syntax_path.write_text(syntax, encoding="utf-8")
    (output_dir / "run_with_spss_external.py").write_text(
        f'''"""Run only with IBM SPSS Statistics' external Python runtime."""
import datetime
import json
import traceback

import spss


status_path = {status_literal}
metadata = json.loads({metadata_json_literal})
metadata["engine"] = "IBM SPSS Statistics external Python"
commands = {commands_literal}
started = False
try:
    spss.StartSPSS()
    started = True
    spss.Submit(commands)
    spss.StopSPSS()
    started = False
    metadata["status"] = "complete"
    metadata["completedAt"] = datetime.datetime.now().isoformat(timespec="seconds")
except Exception as exc:
    metadata["status"] = "failed"
    metadata["error"] = str(exc)
    metadata["traceback"] = traceback.format_exc()
    raise
finally:
    if started:
        try:
            spss.StopSPSS()
        except Exception:
            pass
    with open(status_path, "w", encoding="utf-8") as handle:
        json.dump(metadata, handle, ensure_ascii=False, indent=2)
''',
        encoding="utf-8",
    )
    resolved_output = str(output_dir.resolve())
    forbidden_paths = {
        resolved_output,
        resolved_output.replace("\\", "/"),
        _spss_path(output_dir),
    }
    portable_template = build_portable_spss_template(
        syntax,
        status_literal=status_literal,
        spss_output_path=_spss_path(output_dir),
        forbidden_paths=forbidden_paths,
    )
    (output_dir / "run_with_spss_python_portable.sps.in").write_text(
        portable_template, encoding="utf-8"
    )
    (output_dir / "prepare_portable_spss_run.py").write_text(
        f"""import json
from pathlib import Path

root = Path(__file__).resolve().parent
template = root / "run_with_spss_python_portable.sps.in"
destination = root / "run_with_spss_python_portable.sps"
status_path = str(root / "spss_python_status.json")
portable_root = str(root).replace("\\\\", "/").replace("'", "''")
status_literal = json.dumps(status_path, ensure_ascii=False)
command_json_fragment = json.dumps(portable_root, ensure_ascii=False)[1:-1]
content = template.read_text(encoding="utf-8")
content = content.replace("{PORTABLE_STATUS_LITERAL_TOKEN}", status_literal)
content = content.replace("{PORTABLE_COMMAND_PATH_TOKEN}", command_json_fragment)
if "{PORTABLE_STATUS_LITERAL_TOKEN}" in content or "{PORTABLE_COMMAND_PATH_TOKEN}" in content:
    raise SystemExit("Portable SPSS template replacement was incomplete.")
destination.write_text(content, encoding="utf-8")
print("Portable SPSS run file prepared.")
print("Open this .sps file in IBM SPSS Statistics and choose Run > All.")
""",
        encoding="utf-8",
    )
    (output_dir / "PORTABLE_SPSS_README.md").write_text(
        """# Re-run This Bundle with Licensed IBM SPSS Statistics

The automatically executed `run_with_spss_python.sps` records the original
job path. To prepare an equivalent syntax file after moving or extracting this
bundle on Windows, macOS, or Linux:

```bash
python prepare_portable_spss_run.py
```

Open `run_with_spss_python_portable.sps` in a licensed IBM SPSS Statistics
installation, then choose **Run > All**. Keep `prepared_data.csv` in this same
folder. The helper only rewrites local paths; it does not upload data or call a
network service. IBM SPSS Statistics and its license are not included in this
bundle or in Survey Data Workbench by LAI ZEYU.
""",
        encoding="utf-8",
    )
    return syntax_path


def make_bundle(output_dir: Path) -> Path:
    bundle = output_dir / "Survey_Data_Workbench_完整产出.zip"
    include_suffixes = {
        ".csv",
        ".json",
        ".md",
        ".sps",
        ".sav",
        ".spv",
        ".pdf",
        ".txt",
        ".py",
        ".in",
    }
    sources: list[tuple[Path, int, int]] = []
    total_bytes = 0
    for path in sorted(output_dir.iterdir()):
        if path == bundle or path.name in MACHINE_SPECIFIC_OUTPUTS or path.suffix.lower() not in include_suffixes:
            continue
        if path.is_symlink():
            raise ValueError(f"下载包拒绝符号链接输出：{path.name}")
        if not path.is_file():
            continue
        stat = path.stat()
        if stat.st_size <= 0 or stat.st_size > MAX_BUNDLE_FILE_BYTES:
            raise ValueError(f"下载包输出文件大小超出安全范围：{path.name}")
        total_bytes += stat.st_size
        if total_bytes > MAX_BUNDLE_TOTAL_BYTES:
            raise ValueError("下载包源文件总大小超过 2GB 安全上限")
        sources.append((path, stat.st_size, stat.st_mtime_ns))
    if not sources or len(sources) > MAX_BUNDLE_ENTRIES:
        raise ValueError("下载包输出文件数量超出安全范围")

    with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
        for path, expected_size, expected_mtime_ns in sources:
            archive.write(path, arcname=path.name)
            current = path.stat()
            if current.st_size != expected_size or current.st_mtime_ns != expected_mtime_ns or path.is_symlink():
                raise ValueError(f"下载包源文件在打包期间发生变化：{path.name}")
    with zipfile.ZipFile(bundle, "r") as archive:
        entries = archive.infolist()
        if [entry.filename for entry in entries] != [path.name for path, _, _ in sources]:
            raise ValueError("下载包文件清单与冻结源文件不一致")
        if any(entry.file_size != expected_size for entry, (_, expected_size, _) in zip(entries, sources)):
            raise ValueError("下载包文件大小与冻结源文件不一致")
        corrupt = archive.testzip()
        if corrupt is not None:
            raise ValueError(f"下载包完整性校验失败：{corrupt}")
    return bundle


def output_inventory(
    output_dir: Path,
    *,
    formal_format_validated: bool = False,
) -> list[dict[str, Any]]:
    labels = {
        ".spv": "SPSS 输出查看器",
        ".pdf": "SPSS PDF 报告",
        ".sav": "SPSS 数据文件",
        ".sps": "SPSS Python 驱动语法",
        ".csv": "数据表",
        ".json": "机器可读摘要",
        ".md": "中文摘要",
        ".zip": "完整下载包",
    }
    files = []
    for path in sorted(output_dir.iterdir()):
        if not path.is_file() or path.is_symlink() or path.name in MACHINE_SPECIFIC_OUTPUTS:
            continue
        files.append(
            {
                "name": path.name,
                "size": path.stat().st_size,
                "kind": labels.get(path.suffix.lower(), "输出文件"),
                "provenance": (
                    "ibm_spss_format_validated"
                    if path.name in EXPECTED_FORMAL_OUTPUTS and formal_format_validated
                    else "unverified_ibm_spss"
                    if path.name in EXPECTED_FORMAL_OUTPUTS
                    else "preview_or_supporting_file"
                ),
                "downloadable": True,
            }
        )
    return files


def execute_workflow(
    job_dir: Path,
    config: dict[str, Any],
    update: Callable[[str, int, str], None] | None = None,
) -> dict[str, Any]:
    def notify(stage: str, progress: int, message: str) -> None:
        if update:
            update(stage, progress, message)

    input_files = [path for path in (job_dir / "input").iterdir() if path.is_file() and not path.is_symlink()]
    if len(input_files) != 1:
        raise ValueError("任务必须且只能包含一个普通上传数据文件")
    input_path = input_files[0]
    output_dir = job_dir / "outputs"
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    notify("preparing", 12, "正在读取数据并整理变量")
    frame, _, _ = read_dataset(input_path, config.get("sheet"))
    normalize_dataset_columns(frame)
    constructs = config.get("constructs", [])
    prepared, _, clean_constructs, _ = prepare_data(frame, constructs, output_dir)
    if not clean_constructs:
        raise ValueError("至少需要配置一个包含题项的研究指标")

    notify("preview", 34, "正在生成质量预检和可下载表格")
    models = config.get("models", [])
    preview = build_python_preview(prepared, clean_constructs, models, output_dir)

    notify("syntax", 52, "正在生成 SPSS 内置 Python 驱动")
    analyses = config.get("analyses") or ["descriptives", "reliability", "correlations"]
    syntax_path = generate_spss_python_driver(prepared, clean_constructs, models, analyses, output_dir)
    json_dump(output_dir / "analysis_config.json", config)

    spss_result = {"state": "skipped", "message": "本次仅生成语法和 Python 预检结果。"}
    if config.get("executeSpss", False):
        notify("spss", 62, "正在请求本机 IBM SPSS Statistics 正式执行")
        try:
            spss_result = run_spss_automatically(syntax_path, output_dir)
        except Exception:
            spss_result = {
                "state": "failed",
                "message": "IBM SPSS runner 异常退出；不会报告正式执行成功。",
            }

    if spss_result.get("state") != "complete":
        discarded = []
        for name in EXPECTED_FORMAL_OUTPUTS:
            path = output_dir / name
            if path.is_file():
                path.unlink()
                discarded.append(name)
        if discarded:
            spss_result["discardedPartialOutputs"] = discarded

    notify("packaging", 92, "正在整理下载文件")
    public_execution_status = {
        key: value
        for key, value in spss_result.items()
        if key
        in {
            "state",
            "message",
            "formatIntegrityVerified",
            "integrationVerified",
            "semanticValidation",
            "discardedPartialOutputs",
        }
    }
    json_dump(output_dir / "execution_status.json", public_execution_status)
    bundle = make_bundle(output_dir)
    notify("complete", 100, "分析流程已完成")
    return {
        "state": "complete",
        "preview": preview,
        "spss": spss_result,
        "bundle": bundle.name,
        "files": output_inventory(
            output_dir,
            formal_format_validated=spss_result.get("state") == "complete",
        ),
    }
