from __future__ import annotations

import json
import logging
import zipfile
import zlib
from pathlib import Path
from typing import Any


EXPECTED_FORMAL_OUTPUTS = (
    "analysis_data.sav",
    "analysis_output.spv",
    "analysis_output.pdf",
)

MAX_MARKER_BYTES = 64 * 1024
MAX_SAV_FILE_BYTES = 512 * 1024 * 1024
MAX_SAV_ROWS = 1_000_000
MAX_SAV_COLUMNS = 2_000
MAX_SAV_CELLS = 20_000_000
MAX_SAV_MEMORY_BYTES = 1024 * 1024 * 1024
MAX_SAV_CHUNK_CELLS = 1_000_000
MAX_SPV_FILE_BYTES = 512 * 1024 * 1024
MAX_SPV_ENTRIES = 10_000
MAX_SPV_ENTRY_BYTES = 256 * 1024 * 1024
MAX_SPV_EXPANDED_BYTES = 1024 * 1024 * 1024
MAX_SPV_COMPRESSION_RATIO = 1000
MAX_PDF_FILE_BYTES = 512 * 1024 * 1024
MAX_PDF_DECODED_BYTES = 512 * 1024 * 1024


class _PdfIntegrityLogHandler(logging.Handler):
    """Capture parser warnings that pypdf otherwise only prints and tolerates."""

    def __init__(self) -> None:
        super().__init__(level=logging.WARNING)
        self.messages: list[str] = []

    def emit(self, record: logging.LogRecord) -> None:
        self.messages.append(record.getMessage())


def _validate_pdf_integrity(path: Path) -> dict[str, int | str]:
    """Strictly parse the PDF and force every indirect stream to decode.

    ``PdfReader`` is intentionally tolerant: a damaged Flate content stream can
    produce an empty byte string while only logging an error.  A release gate
    must turn that condition into a hard failure instead of accepting a PDF
    whose page tree and media boxes happen to remain readable.
    """

    if path.stat().st_size > MAX_PDF_FILE_BYTES:
        raise ValueError("PDF exceeds the 512 MiB encoded-file integrity limit")

    from pypdf import PdfReader
    from pypdf.generic import IndirectObject, StreamObject

    parser_log = logging.getLogger("pypdf")
    capture = _PdfIntegrityLogHandler()
    parser_log.addHandler(capture)
    try:
        reader = PdfReader(str(path), strict=True)
        page_count = len(reader.pages)
        if page_count <= 0:
            raise ValueError("PDF contains no readable pages")

        references: set[tuple[int, int]] = set()
        for generation, object_ids in reader.xref.items():
            references.update((int(object_id), int(generation)) for object_id in object_ids)
        references.update((int(object_id), 0) for object_id in reader.xref_objStm)

        decoded_streams = 0
        decoded_bytes = 0
        for object_id, generation in sorted(references):
            value = reader.get_object(IndirectObject(object_id, generation, reader))
            if not isinstance(value, StreamObject):
                continue
            decoded = value.get_data()
            # A correctly encoded Flate stream may legitimately decode to zero
            # bytes.  Corrupt streams are rejected through strict parsing and
            # the captured pypdf warning channel instead of an empty-result
            # heuristic that would reject that valid case.
            decoded_streams += 1
            decoded_bytes += len(decoded)
            if decoded_bytes > MAX_PDF_DECODED_BYTES:
                raise ValueError("PDF decoded stream data exceeds the 512 MiB integrity limit")

        # Resolve each page's inherited /Contents value as an additional guard
        # for PDFs whose page content is represented by an array of streams.
        for page in reader.pages:
            _ = page.mediabox
            contents = page.get_contents()
            if contents is not None:
                _ = contents.get_data()

        if capture.messages:
            raise ValueError("pypdf reported an integrity warning: " + capture.messages[0])
        return {
            "parser": "pypdf-strict-stream-decode",
            "pages": page_count,
            "decodedStreams": decoded_streams,
        }
    finally:
        parser_log.removeHandler(capture)


def marker_result(output_dir: Path, *, success_message: str) -> dict[str, Any]:
    marker = output_dir / "spss_python_status.json"
    if not marker.is_file():
        return {
            "state": "failed",
            "message": "IBM SPSS 未返回可信完成标记，因此不会报告正式执行成功。",
        }
    if marker.stat().st_size > MAX_MARKER_BYTES:
        return {
            "state": "failed",
            "message": "IBM SPSS 完成标记超过安全读取上限，因此不会报告正式执行成功。",
        }
    try:
        details = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return {
            "state": "failed",
            "message": "IBM SPSS 完成标记无法读取，因此不会报告正式执行成功。",
            "details": {"error": str(error)},
        }

    if details.get("status") != "complete":
        return {
            "state": "failed",
            "message": "IBM SPSS 执行失败；Python 预检和语法仍可使用。",
            "details": details,
        }

    missing = [
        name
        for name in EXPECTED_FORMAL_OUTPUTS
        if not (output_dir / name).is_file() or (output_dir / name).stat().st_size == 0
    ]
    if missing:
        return {
            "state": "failed",
            "message": "IBM SPSS 标记已完成，但正式输出不完整，因此不会报告成功。",
            "details": {**details, "missingOutputs": missing},
        }

    validation: dict[str, Any] = {}
    invalid: dict[str, str] = {}

    try:
        import pyreadstat

        sav_path = output_dir / "analysis_data.sav"
        if sav_path.stat().st_size > MAX_SAV_FILE_BYTES:
            raise ValueError("SAV exceeds the 512 MiB encoded-file integrity limit")
        _, metadata_only = pyreadstat.read_sav(
            str(sav_path),
            metadataonly=True,
        )
        metadata_rows = int(getattr(metadata_only, "number_rows", 0) or 0)
        metadata_columns = len(getattr(metadata_only, "column_names", ()) or ())
        if metadata_rows < 0 or metadata_rows > MAX_SAV_ROWS:
            raise ValueError(f"SAV row count exceeds the {MAX_SAV_ROWS:,} row limit")
        if metadata_columns <= 0 or metadata_columns > MAX_SAV_COLUMNS:
            raise ValueError(f"SAV variable count exceeds the {MAX_SAV_COLUMNS:,} variable limit")
        if metadata_rows * metadata_columns > MAX_SAV_CELLS:
            raise ValueError(f"SAV exceeds the {MAX_SAV_CELLS:,} parsed-cell limit")

        expected_columns = tuple(getattr(metadata_only, "column_names", ()) or ())
        column_count = len(expected_columns)
        parsed_rows = 0
        frame_memory = 0
        # Parse every row while bounding live pandas memory. A single full-frame
        # read would turn the post-parse memory check into an ineffective limit.
        chunk_rows = max(1, min(100_000, MAX_SAV_CHUNK_CELLS // column_count))
        while parsed_rows < metadata_rows or (metadata_rows == 0 and parsed_rows == 0):
            requested_rows = min(chunk_rows, metadata_rows - parsed_rows) if metadata_rows else 1
            sav_frame, sav_metadata = pyreadstat.read_sav(
                str(sav_path),
                row_offset=parsed_rows,
                row_limit=requested_rows,
            )
            if tuple(sav_frame.columns) != expected_columns:
                raise ValueError("SAV variables changed between metadata preflight and bounded parsing")
            rows_in_chunk = len(sav_frame.index)
            if metadata_rows == 0:
                if rows_in_chunk != 0:
                    raise ValueError("SAV metadata reported zero rows but bounded parsing returned data")
            elif rows_in_chunk != requested_rows:
                raise ValueError(
                    "SAV bounded parser returned an incomplete row chunk: "
                    f"offset={parsed_rows}, requested={requested_rows}, parsed={rows_in_chunk}"
                )
            parsed_metadata_rows = int(getattr(sav_metadata, "number_rows", metadata_rows) or 0)
            if parsed_metadata_rows not in (0, metadata_rows):
                raise ValueError(
                    "SAV metadata row count changed during bounded parsing: "
                    f"preflight={metadata_rows}, parsed-metadata={parsed_metadata_rows}"
                )
            frame_memory += int(sav_frame.memory_usage(index=True, deep=True).sum())
            if frame_memory > MAX_SAV_MEMORY_BYTES:
                raise ValueError("SAV parsed data exceeds the 1 GiB cumulative memory-accounting limit")
            parsed_rows += rows_in_chunk
            if metadata_rows == 0:
                break
        if parsed_rows != metadata_rows:
            raise ValueError(f"SAV metadata/data row mismatch: preflight={metadata_rows}, parsed={parsed_rows}")
        validation["analysis_data.sav"] = {
            "parser": "pyreadstat",
            "columns": column_count,
            "rows": parsed_rows,
            "memoryBytes": frame_memory,
            "maxChunkCells": MAX_SAV_CHUNK_CELLS,
        }
    except Exception as error:  # parser exception types vary by wheel version
        invalid["SAV"] = str(error)

    try:
        spv_path = output_dir / "analysis_output.spv"
        if spv_path.stat().st_size > MAX_SPV_FILE_BYTES:
            raise ValueError("SPV exceeds the 512 MiB encoded-file integrity limit")
        with zipfile.ZipFile(spv_path, "r") as archive:
            entries = [item for item in archive.infolist() if not item.is_dir()]
            if not entries:
                raise ValueError("SPV archive contains no files")
            if len(entries) > MAX_SPV_ENTRIES:
                raise ValueError(f"SPV contains more than {MAX_SPV_ENTRIES:,} file entries")
            declared_expanded = sum(item.file_size for item in entries)
            if declared_expanded > MAX_SPV_EXPANDED_BYTES:
                raise ValueError("SPV declared expanded data exceeds the 1 GiB integrity limit")
            seen_names: set[str] = set()
            for item in entries:
                name = item.filename.replace("\\", "/")
                parts = name.split("/")
                if (
                    not name
                    or name.startswith("/")
                    or any(part in {"", ".", ".."} for part in parts)
                    or name.casefold() in seen_names
                    or item.flag_bits & 0x1
                ):
                    raise ValueError("SPV archive contains an unsafe, duplicate, or encrypted entry")
                seen_names.add(name.casefold())
                if item.file_size > MAX_SPV_ENTRY_BYTES:
                    raise ValueError(f"SPV entry exceeds the 256 MiB limit: {item.filename}")
                if item.file_size and item.compress_size == 0:
                    raise ValueError(f"SPV entry has an impossible compression size: {item.filename}")
                if item.compress_size and item.file_size / item.compress_size > MAX_SPV_COMPRESSION_RATIO:
                    raise ValueError(f"SPV entry exceeds the compression-ratio limit: {item.filename}")
            corrupt = archive.testzip()
            if corrupt is not None:
                raise ValueError(f"SPV archive has a corrupt entry: {corrupt}")
            expanded_bytes = 0
            for item in entries:
                with archive.open(item, "r") as source:
                    entry_bytes = 0
                    while chunk := source.read(1024 * 1024):
                        entry_bytes += len(chunk)
                        expanded_bytes += len(chunk)
                        if entry_bytes > MAX_SPV_ENTRY_BYTES or expanded_bytes > MAX_SPV_EXPANDED_BYTES:
                            raise ValueError("SPV expanded data exceeded its bounded integrity limit")
                    if entry_bytes != item.file_size:
                        raise ValueError(f"SPV entry size changed during full read: {item.filename}")
            validation["analysis_output.spv"] = {
                "parser": "zipfile",
                "entries": len(entries),
                "expandedBytes": expanded_bytes,
            }
    except (OSError, ValueError, zipfile.BadZipFile, RuntimeError, zlib.error) as error:
        invalid["SPV"] = str(error)

    try:
        validation["analysis_output.pdf"] = _validate_pdf_integrity(
            output_dir / "analysis_output.pdf"
        )
    except Exception as error:  # pypdf exposes several structured parse errors
        invalid["PDF"] = str(error)

    if invalid:
        return {
            "state": "failed",
            "message": "IBM SPSS 返回的正式文件未通过完整格式解析，因此不会报告成功。",
            "details": {**details, "invalidOutputFormats": invalid},
        }

    return {
        "state": "complete",
        "message": success_message,
        "formatIntegrityVerified": True,
        "integrationVerified": False,
        "semanticValidation": "external_two_environment_gate_required",
        "details": {
            **details,
            "formatValidation": validation,
            "validatedOutputSizes": {
                name: (output_dir / name).stat().st_size for name in EXPECTED_FORMAL_OUTPUTS
            },
        },
    }


class UnsupportedSpssRunner:
    def __init__(self, platform_name: str) -> None:
        self.platform_name = platform_name

    def status(self) -> dict[str, Any]:
        return {
            "installed": False,
            "licenseState": "unavailable",
            "executionMode": "Python 预检模式",
            "platform": self.platform_name,
            "integrationVerified": False,
            "note": "当前系统不支持 IBM SPSS 自动执行，仍可生成 Python 预检、语法和下载包。",
        }

    def run(self, syntax_path: Path, output_dir: Path, timeout_seconds: int) -> dict[str, Any]:
        del syntax_path, output_dir, timeout_seconds
        return {"state": "unavailable", "message": self.status()["note"]}
