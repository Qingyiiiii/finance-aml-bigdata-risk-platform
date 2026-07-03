# -*- coding: utf-8 -*-
"""Shared helpers for the finance_bigdata local pipeline."""
from __future__ import annotations

import csv
import json
from datetime import datetime
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]

TRANSACTION_RAW_COLUMNS = [
    "Timestamp",
    "From Bank",
    "Account",
    "To Bank",
    "Account",
    "Amount Received",
    "Receiving Currency",
    "Amount Paid",
    "Payment Currency",
    "Payment Format",
    "Is Laundering",
]

TRANSACTION_ODS_COLUMNS = [
    "timestamp",
    "from_bank",
    "from_account",
    "to_bank",
    "to_account",
    "amount_received",
    "receiving_currency",
    "amount_paid",
    "payment_currency",
    "payment_format",
    "is_laundering",
]

ACCOUNT_ODS_COLUMNS = [
    "bank_name",
    "bank_id",
    "account_number",
    "entity_id",
    "entity_name",
]


def parse_scalar(value: str) -> Any:
    """Parse the small scalar subset used by this project's YAML files."""
    value = value.strip()
    if value == "":
        return ""
    if value.lower() in {"true", "false"}:
        return value.lower() == "true"
    if value.lower() in {"null", "none"}:
        return None
    if (value.startswith('"') and value.endswith('"')) or (
        value.startswith("'") and value.endswith("'")
    ):
        return value[1:-1]
    try:
        return int(value)
    except ValueError:
        return value


def load_simple_yaml(path: Path) -> dict[str, Any]:
    """Load the simple nested YAML structure used by finance_bigdata configs."""
    data: dict[str, Any] = {}
    stack: list[tuple[int, dict[str, Any]]] = [(-1, data)]
    with path.open("r", encoding="utf-8") as fh:
        for raw_line in fh:
            if not raw_line.strip() or raw_line.lstrip().startswith("#"):
                continue
            indent = len(raw_line) - len(raw_line.lstrip(" "))
            line = raw_line.strip()
            if ":" not in line:
                raise ValueError(f"Unsupported config line: {raw_line.rstrip()}")
            key, value = line.split(":", 1)
            key = key.strip()
            value = value.strip()
            while indent <= stack[-1][0]:
                stack.pop()
            parent = stack[-1][1]
            if value == "":
                child: dict[str, Any] = {}
                parent[key] = child
                stack.append((indent, child))
            else:
                parent[key] = parse_scalar(value)
    return data


def load_config(config_path: str | Path) -> dict[str, Any]:
    path = Path(config_path)
    if not path.is_absolute():
        path = PROJECT_ROOT / path
    if not path.exists():
        raise FileNotFoundError(f"Config not found: {path}")
    return load_simple_yaml(path)


def project_path(value: str | Path) -> Path:
    path = Path(value)
    if path.is_absolute():
        return path
    return PROJECT_ROOT / path


def configured_paths(config: dict[str, Any]) -> dict[str, Path]:
    """Resolve raw-data and output paths from the active finance config."""
    raw_dir = project_path(config["paths"]["raw_dir"])
    output_dir = project_path(config["paths"]["output_dir"])
    datasets = config["datasets"]
    return {
        "raw_dir": raw_dir,
        "output_dir": output_dir,
        "transaction": raw_dir / datasets["transaction_file"],
        "account": raw_dir / datasets["account_file"],
        "pattern": raw_dir / datasets["pattern_file"],
    }


def timestamped_run_dir(output_dir: Path, prefix: str) -> Path:
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = output_dir / "runs" / f"{prefix}_{stamp}"
    run_dir.mkdir(parents=True, exist_ok=False)
    return run_dir


def read_csv_header(path: Path) -> list[str]:
    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        reader = csv.reader(fh)
        return next(reader)


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


def write_tsv(path: Path, rows: list[dict[str, Any]], columns: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=columns, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({column: row.get(column, "") for column in columns})


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)
        if not content.endswith("\n"):
            fh.write("\n")


def parse_source_timestamp(value: str) -> dict[str, Any]:
    try:
        dt = datetime.strptime(value.strip(), "%Y/%m/%d %H:%M")
    except ValueError:
        return {
            "transaction_date": "",
            "transaction_hour": "",
            "transaction_minute": "",
            "timestamp_parse_status": "fail",
        }
    return {
        "transaction_date": dt.strftime("%Y-%m-%d"),
        "transaction_hour": dt.hour,
        "transaction_minute": dt.strftime("%Y-%m-%d %H:%M"),
        "timestamp_parse_status": "pass",
    }


def normalize_transaction_row(row: list[str]) -> dict[str, Any]:
    """Map one raw transaction CSV row into the project's ODS field names."""
    if len(row) != len(TRANSACTION_ODS_COLUMNS):
        raise ValueError(f"Expected 11 columns, got {len(row)}")
    return dict(zip(TRANSACTION_ODS_COLUMNS, [value.strip() for value in row]))


def parse_float(value: str) -> float | None:
    text = value.strip().replace(",", "")
    if text == "":
        return None
    try:
        return float(text)
    except ValueError:
        return None


def format_top_counter(counter: Any, limit: int = 15) -> list[dict[str, Any]]:
    return [{"value": key, "count": count} for key, count in counter.most_common(limit)]


def file_size_mb(path: Path) -> str:
    return f"{path.stat().st_size / 1024 / 1024:.2f}"


class OptionalParquetWriter:
    """Chunked optional Parquet writer used by P3/P4 without making pyarrow mandatory."""

    def __init__(self, path: Path, enabled: bool = True, chunk_size: int = 100000):
        self.path = path
        self.enabled = enabled
        self.chunk_size = chunk_size
        self.buffer: list[dict[str, Any]] = []
        self.rows_written = 0
        self.detail = "disabled"
        self._writer = None
        self._pa = None
        self._pq = None
        if not enabled:
            return
        try:
            import pyarrow as pa  # type: ignore
            import pyarrow.parquet as pq  # type: ignore
        except Exception as exc:  # pragma: no cover - local dependency dependent
            self.enabled = False
            self.detail = f"pyarrow unavailable: {exc}"
            return
        self._pa = pa
        self._pq = pq
        self.detail = "ready"

    def write(self, row: dict[str, Any]) -> None:
        if not self.enabled:
            return
        self.buffer.append(row)
        if len(self.buffer) >= self.chunk_size:
            self.flush()

    def flush(self) -> None:
        if not self.enabled or not self.buffer:
            return
        table = self._pa.Table.from_pylist(self.buffer)
        if self._writer is None:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self._writer = self._pq.ParquetWriter(self.path, table.schema)
        self._writer.write_table(table)
        self.rows_written += len(self.buffer)
        self.buffer = []
        self.detail = "written"

    def close(self) -> None:
        self.flush()
        if self._writer is not None:
            self._writer.close()
            self._writer = None
