# -*- coding: utf-8 -*-
"""Shared utilities for P9/P16 finance analysis scripts."""
from __future__ import annotations

import csv
import json
from datetime import datetime
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def project_path(value: str | Path) -> Path:
    """Resolve a user/config path against the finance project root."""
    path = Path(value)
    if path.is_absolute():
        return path
    return PROJECT_ROOT / path


def timestamped_run_dir(prefix: str) -> Path:
    """Create a timestamped run directory under data/finance_bigdata/runs."""
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = PROJECT_ROOT / "data" / "finance_bigdata" / "runs" / f"{prefix}_{stamp}"
    run_dir.mkdir(parents=True, exist_ok=False)
    return run_dir


def write_tsv(path: Path, rows: list[dict[str, Any]], columns: list[str]) -> None:
    """Write rows as a stable tab-separated evidence file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=columns, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow({column: row.get(column, "") for column in columns})


def write_json(path: Path, payload: Any) -> None:
    """Write JSON evidence with UTF-8 and readable indentation."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


def write_text(path: Path, content: str) -> None:
    """Write Markdown or plain-text evidence with a trailing newline."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)
        if not content.endswith("\n"):
            fh.write("\n")


def parse_metric_tsv(path: Path) -> dict[str, str]:
    """Read a two-column metric/value TSV into a dictionary."""
    metrics: dict[str, str] = {}
    with path.open("r", encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        for row in reader:
            metrics[row["metric"]] = row["value"]
    return metrics


def latest_run_dir(prefix: str) -> Path:
    """Locate the newest run directory for a given analysis prefix."""
    runs_dir = PROJECT_ROOT / "data" / "finance_bigdata" / "runs"
    candidates = sorted(runs_dir.glob(f"{prefix}_*"))
    if not candidates:
        raise FileNotFoundError(f"No run directory found for prefix: {prefix}")
    return candidates[-1]
