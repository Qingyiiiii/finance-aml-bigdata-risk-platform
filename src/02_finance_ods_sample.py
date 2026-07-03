# -*- coding: utf-8 -*-
"""Build a typed ODS sample from the raw HI-Small transaction file."""
from __future__ import annotations

import argparse
import csv
from collections import Counter
from pathlib import Path
from typing import Any

from finance_utils import (
    TRANSACTION_ODS_COLUMNS,
    configured_paths,
    load_config,
    normalize_transaction_row,
    parse_float,
    timestamped_run_dir,
    write_json,
    write_text,
    write_tsv,
)


def typed_ods_row(row: list[str]) -> dict[str, Any]:
    """Convert one raw transaction row into the typed ODS sample schema."""
    tx = normalize_transaction_row(row)
    return {
        "timestamp": tx["timestamp"],
        "from_bank": tx["from_bank"],
        "from_account": tx["from_account"],
        "to_bank": tx["to_bank"],
        "to_account": tx["to_account"],
        "amount_received": parse_float(tx["amount_received"]),
        "receiving_currency": tx["receiving_currency"],
        "amount_paid": parse_float(tx["amount_paid"]),
        "payment_currency": tx["payment_currency"],
        "payment_format": tx["payment_format"],
        "is_laundering": int(tx["is_laundering"]),
    }


def write_optional_parquet(rows: list[dict[str, Any]], path: Path) -> tuple[bool, str]:
    """Write the ODS sample as Parquet when pyarrow is available."""
    try:
        import pyarrow as pa  # type: ignore
        import pyarrow.parquet as pq  # type: ignore
    except Exception as exc:  # pragma: no cover - dependency depends on local env
        return False, f"pyarrow unavailable: {exc}"

    table = pa.Table.from_pylist(rows)
    pq.write_table(table, path)
    return True, "written"


def build_schema_doc() -> str:
    """Build the ODS schema explanation used by the P2 evidence package."""
    rows = [
        ("timestamp", "string", "Raw transaction timestamp, kept in source timezone semantics"),
        ("from_bank", "string", "Sender bank id"),
        ("from_account", "string", "Sender account id"),
        ("to_bank", "string", "Receiver bank id"),
        ("to_account", "string", "Receiver account id"),
        ("amount_received", "double", "Amount received by target account"),
        ("receiving_currency", "string", "Currency of received amount"),
        ("amount_paid", "double", "Amount paid by source account"),
        ("payment_currency", "string", "Currency of paid amount"),
        ("payment_format", "string", "Payment channel or format"),
        ("is_laundering", "int", "1 means laundering-labeled transaction, 0 means normal"),
    ]
    lines = [
        "# ODS Finance Transactions Sample Schema",
        "",
        "| Column | Type | Description |",
        "| --- | --- | --- |",
    ]
    for column, data_type, description in rows:
        lines.append(f"| {column} | {data_type} | {description} |")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="P2 finance ODS sample generation.")
    parser.add_argument("--config", default="config/finance_bigdata.local.yaml")
    args = parser.parse_args()

    config = load_config(args.config)
    paths = configured_paths(config)
    sample_rows = int(config["processing"]["sample_rows"])
    write_parquet = bool(config["processing"].get("write_parquet_if_available", True))
    run_dir = timestamped_run_dir(paths["output_dir"], "p2_ods_sample")

    csv_path = run_dir / "ods_finance_transactions_sample.csv"
    parquet_path = run_dir / "ods_finance_transactions_sample.parquet"
    retained_rows: list[dict[str, Any]] = []
    label_counts: Counter[str] = Counter()
    payment_format_counts: Counter[str] = Counter()
    malformed_count = 0
    min_timestamp = ""
    max_timestamp = ""

    with paths["transaction"].open("r", encoding="utf-8-sig", newline="") as source, csv_path.open(
        "w", encoding="utf-8", newline=""
    ) as target:
        reader = csv.reader(source)
        next(reader)
        writer = csv.DictWriter(target, fieldnames=TRANSACTION_ODS_COLUMNS, lineterminator="\n")
        writer.writeheader()

        for row in reader:
            if len(row) != len(TRANSACTION_ODS_COLUMNS):
                malformed_count += 1
                continue
            typed = typed_ods_row(row)
            writer.writerow(typed)
            retained_rows.append(typed)
            label_counts[str(typed["is_laundering"])] += 1
            payment_format_counts[str(typed["payment_format"])] += 1
            ts = str(typed["timestamp"])
            if ts:
                if not min_timestamp or ts < min_timestamp:
                    min_timestamp = ts
                if not max_timestamp or ts > max_timestamp:
                    max_timestamp = ts
            if len(retained_rows) >= sample_rows:
                break

    parquet_written = False
    parquet_detail = "disabled"
    if write_parquet:
        parquet_written, parquet_detail = write_optional_parquet(retained_rows, parquet_path)

    summary = {
        "source_file": str(paths["transaction"]),
        "run_dir": str(run_dir),
        "csv_path": str(csv_path),
        "parquet_path": str(parquet_path) if parquet_written else "",
        "parquet_status": parquet_detail,
        "rows_written": len(retained_rows),
        "malformed_rows_skipped": malformed_count,
        "min_timestamp": min_timestamp,
        "max_timestamp": max_timestamp,
        "label_counts": dict(label_counts),
        "payment_format_counts": dict(payment_format_counts),
    }

    write_json(run_dir / "ods_validation_summary.json", summary)
    write_tsv(
        run_dir / "ods_validation_summary.tsv",
        [{"metric": key, "value": value} for key, value in summary.items() if key != "payment_format_counts"],
        ["metric", "value"],
    )
    write_text(run_dir / "ods_schema.md", build_schema_doc())
    write_text(
        run_dir / "ods_validation_summary.md",
        "\n".join(
            [
                "# P2 ODS Sample Validation Summary",
                "",
                f"- Run dir: `{run_dir}`",
                f"- Source file: `{paths['transaction']}`",
                f"- CSV output: `{csv_path}`",
                f"- Rows written: `{len(retained_rows)}`",
                f"- Malformed rows skipped before sample completion: `{malformed_count}`",
                f"- Time range in sample: `{min_timestamp}` to `{max_timestamp}`",
                f"- Label counts: `{dict(label_counts)}`",
                f"- Parquet status: `{parquet_detail}`",
            ]
        ),
    )

    print(f"P2_RUN_DIR={run_dir}")
    print("P2_STATUS=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
