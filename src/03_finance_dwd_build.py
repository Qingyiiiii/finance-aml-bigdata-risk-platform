# -*- coding: utf-8 -*-
"""Build P3 DWD finance transaction, account, and event-detail tables."""
from __future__ import annotations

import argparse
import csv
from collections import Counter
from pathlib import Path
from typing import Any

from finance_utils import (
    OptionalParquetWriter,
    TRANSACTION_ODS_COLUMNS,
    configured_paths,
    load_config,
    normalize_transaction_row,
    parse_float,
    parse_source_timestamp,
    timestamped_run_dir,
    write_json,
    write_text,
    write_tsv,
)


DWD_TRANSACTION_COLUMNS = [
    "transaction_id",
    "timestamp",
    "transaction_date",
    "transaction_hour",
    "transaction_minute",
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
    "is_cross_bank",
    "is_cross_currency",
]

DWD_ACCOUNT_COLUMNS = [
    "bank_name",
    "bank_id",
    "account_number",
    "entity_id",
    "entity_name",
]

DWD_EVENT_COLUMNS = [
    "transaction_id",
    "timestamp",
    "transaction_minute",
    "event_type",
    "event_account",
    "counterparty_account",
    "bank_id",
    "counterparty_bank_id",
    "event_amount",
    "currency",
    "payment_format",
    "is_laundering",
    "is_cross_bank",
    "is_cross_currency",
]


def standardize_account_row(row: list[str]) -> dict[str, Any]:
    """Normalize one raw account row into the DWD account dimension schema."""
    return {
        "bank_name": row[0].strip(),
        "bank_id": row[1].strip(),
        "account_number": row[2].strip(),
        "entity_id": row[3].strip(),
        "entity_name": row[4].strip(),
    }


def build_transaction_row(raw: list[str], sequence: int) -> dict[str, Any]:
    """Build one DWD transaction fact row from the raw transaction CSV row."""
    tx = normalize_transaction_row(raw)
    parsed_time = parse_source_timestamp(tx["timestamp"])
    amount_received = parse_float(tx["amount_received"])
    amount_paid = parse_float(tx["amount_paid"])
    return {
        "transaction_id": f"HI_SMALL_{sequence:010d}",
        "timestamp": tx["timestamp"],
        "transaction_date": parsed_time["transaction_date"],
        "transaction_hour": parsed_time["transaction_hour"],
        "transaction_minute": parsed_time["transaction_minute"],
        "from_bank": tx["from_bank"],
        "from_account": tx["from_account"],
        "to_bank": tx["to_bank"],
        "to_account": tx["to_account"],
        "amount_received": amount_received,
        "receiving_currency": tx["receiving_currency"],
        "amount_paid": amount_paid,
        "payment_currency": tx["payment_currency"],
        "payment_format": tx["payment_format"],
        "is_laundering": int(tx["is_laundering"]),
        "is_cross_bank": int(tx["from_bank"] != tx["to_bank"]),
        "is_cross_currency": int(tx["receiving_currency"] != tx["payment_currency"]),
    }


def transaction_to_events(row: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    """Split one transaction into debit and credit event rows."""
    debit = {
        "transaction_id": row["transaction_id"],
        "timestamp": row["timestamp"],
        "transaction_minute": row["transaction_minute"],
        "event_type": "DEBIT",
        "event_account": row["from_account"],
        "counterparty_account": row["to_account"],
        "bank_id": row["from_bank"],
        "counterparty_bank_id": row["to_bank"],
        "event_amount": row["amount_paid"],
        "currency": row["payment_currency"],
        "payment_format": row["payment_format"],
        "is_laundering": row["is_laundering"],
        "is_cross_bank": row["is_cross_bank"],
        "is_cross_currency": row["is_cross_currency"],
    }
    credit = {
        "transaction_id": row["transaction_id"],
        "timestamp": row["timestamp"],
        "transaction_minute": row["transaction_minute"],
        "event_type": "CREDIT",
        "event_account": row["to_account"],
        "counterparty_account": row["from_account"],
        "bank_id": row["to_bank"],
        "counterparty_bank_id": row["from_bank"],
        "event_amount": row["amount_received"],
        "currency": row["receiving_currency"],
        "payment_format": row["payment_format"],
        "is_laundering": row["is_laundering"],
        "is_cross_bank": row["is_cross_bank"],
        "is_cross_currency": row["is_cross_currency"],
    }
    return debit, credit


def write_accounts(account_path: Path, run_dir: Path, write_parquet: bool) -> tuple[set[str], dict[str, Any]]:
    """Write the DWD account dimension and return known account ids."""
    output_csv = run_dir / "dwd_finance_accounts.csv"
    output_parquet = run_dir / "dwd_finance_accounts.parquet"
    parquet_writer = OptionalParquetWriter(output_parquet, enabled=write_parquet, chunk_size=100000)
    account_numbers: set[str] = set()
    source_rows = 0
    malformed = 0
    bank_ids: set[str] = set()
    entity_ids: set[str] = set()

    with account_path.open("r", encoding="utf-8-sig", newline="") as source, output_csv.open(
        "w", encoding="utf-8", newline=""
    ) as target:
        reader = csv.reader(source)
        next(reader)
        writer = csv.DictWriter(target, fieldnames=DWD_ACCOUNT_COLUMNS, lineterminator="\n")
        writer.writeheader()
        for raw in reader:
            if len(raw) != 5:
                malformed += 1
                continue
            source_rows += 1
            row = standardize_account_row(raw)
            writer.writerow(row)
            parquet_writer.write(row)
            account_numbers.add(row["account_number"])
            bank_ids.add(row["bank_id"])
            entity_ids.add(row["entity_id"])

    parquet_writer.close()
    return account_numbers, {
        "csv_path": str(output_csv),
        "parquet_path": str(output_parquet) if parquet_writer.rows_written else "",
        "parquet_status": parquet_writer.detail,
        "row_count": source_rows,
        "unique_account_count": len(account_numbers),
        "duplicate_account_number_count": source_rows - len(account_numbers),
        "malformed_count": malformed,
        "bank_count": len(bank_ids),
        "entity_count": len(entity_ids),
    }


def write_transactions_and_events(
    transaction_path: Path,
    run_dir: Path,
    account_numbers: set[str],
    write_parquet: bool,
) -> dict[str, Any]:
    """Stream raw transactions into DWD transaction facts and account events."""
    transaction_csv = run_dir / "dwd_finance_transactions.csv"
    transaction_parquet = run_dir / "dwd_finance_transactions.parquet"
    event_csv = run_dir / "dwd_finance_transaction_events.csv"
    event_parquet = run_dir / "dwd_finance_transaction_events.parquet"
    tx_parquet_writer = OptionalParquetWriter(transaction_parquet, enabled=write_parquet, chunk_size=100000)
    event_parquet_writer = OptionalParquetWriter(event_parquet, enabled=write_parquet, chunk_size=200000)

    stats: dict[str, Any] = {
        "transaction_csv_path": str(transaction_csv),
        "transaction_parquet_path": "",
        "transaction_parquet_status": tx_parquet_writer.detail,
        "event_csv_path": str(event_csv),
        "event_parquet_path": "",
        "event_parquet_status": event_parquet_writer.detail,
        "transaction_row_count": 0,
        "event_row_count": 0,
        "malformed_count": 0,
        "invalid_amount_count": 0,
        "invalid_timestamp_count": 0,
        "from_account_missing_count": 0,
        "to_account_missing_count": 0,
        "from_account_match_rate": 0.0,
        "to_account_match_rate": 0.0,
        "label_counts": Counter(),
        "payment_format_counts": Counter(),
        "cross_bank_count": 0,
        "cross_currency_count": 0,
        "missing_account_examples": [],
    }

    with transaction_path.open("r", encoding="utf-8-sig", newline="") as source, transaction_csv.open(
        "w", encoding="utf-8", newline=""
    ) as tx_target, event_csv.open("w", encoding="utf-8", newline="") as event_target:
        reader = csv.reader(source)
        next(reader)
        tx_writer = csv.DictWriter(tx_target, fieldnames=DWD_TRANSACTION_COLUMNS, lineterminator="\n")
        event_writer = csv.DictWriter(event_target, fieldnames=DWD_EVENT_COLUMNS, lineterminator="\n")
        tx_writer.writeheader()
        event_writer.writeheader()

        sequence = 0
        for raw in reader:
            if len(raw) != len(TRANSACTION_ODS_COLUMNS):
                stats["malformed_count"] += 1
                continue
            sequence += 1
            row = build_transaction_row(raw, sequence)
            if row["amount_paid"] is None or row["amount_received"] is None:
                stats["invalid_amount_count"] += 1
                continue
            if not row["transaction_minute"]:
                stats["invalid_timestamp_count"] += 1

            tx_writer.writerow(row)
            tx_parquet_writer.write(row)
            stats["transaction_row_count"] += 1
            stats["label_counts"][str(row["is_laundering"])] += 1
            stats["payment_format_counts"][str(row["payment_format"])] += 1
            stats["cross_bank_count"] += int(row["is_cross_bank"])
            stats["cross_currency_count"] += int(row["is_cross_currency"])

            if row["from_account"] not in account_numbers:
                stats["from_account_missing_count"] += 1
                if len(stats["missing_account_examples"]) < 20:
                    stats["missing_account_examples"].append(
                        {"side": "from", "account": row["from_account"], "transaction_id": row["transaction_id"]}
                    )
            if row["to_account"] not in account_numbers:
                stats["to_account_missing_count"] += 1
                if len(stats["missing_account_examples"]) < 20:
                    stats["missing_account_examples"].append(
                        {"side": "to", "account": row["to_account"], "transaction_id": row["transaction_id"]}
                    )

            for event in transaction_to_events(row):
                event_writer.writerow(event)
                event_parquet_writer.write(event)
                stats["event_row_count"] += 1

    tx_parquet_writer.close()
    event_parquet_writer.close()
    stats["transaction_parquet_status"] = tx_parquet_writer.detail
    stats["event_parquet_status"] = event_parquet_writer.detail
    if tx_parquet_writer.rows_written:
        stats["transaction_parquet_path"] = str(transaction_parquet)
    if event_parquet_writer.rows_written:
        stats["event_parquet_path"] = str(event_parquet)
    if stats["transaction_row_count"]:
        stats["from_account_match_rate"] = 1 - stats["from_account_missing_count"] / stats["transaction_row_count"]
        stats["to_account_match_rate"] = 1 - stats["to_account_missing_count"] / stats["transaction_row_count"]
    return stats


def serializable_stats(stats: dict[str, Any]) -> dict[str, Any]:
    result = {}
    for key, value in stats.items():
        if isinstance(value, Counter):
            result[key] = dict(value)
        else:
            result[key] = value
    return result


def build_report(run_dir: Path, account_stats: dict[str, Any], tx_stats: dict[str, Any]) -> str:
    return "\n".join(
        [
            "# P3 DWD Build Report",
            "",
            f"- Run dir: `{run_dir}`",
            f"- Account rows: `{account_stats['row_count']}`",
            f"- Unique account numbers: `{account_stats['unique_account_count']}`",
            f"- Duplicate account number rows: `{account_stats['duplicate_account_number_count']}`",
            f"- Transaction rows: `{tx_stats['transaction_row_count']}`",
            f"- Event rows: `{tx_stats['event_row_count']}`",
            f"- Transaction malformed rows: `{tx_stats['malformed_count']}`",
            f"- Invalid amount rows skipped: `{tx_stats['invalid_amount_count']}`",
            f"- From-account match rate: `{tx_stats['from_account_match_rate']:.6%}`",
            f"- To-account match rate: `{tx_stats['to_account_match_rate']:.6%}`",
            f"- Cross-bank transactions: `{tx_stats['cross_bank_count']}`",
            f"- Cross-currency transactions: `{tx_stats['cross_currency_count']}`",
            f"- Transaction Parquet status: `{tx_stats['transaction_parquet_status']}`",
            f"- Event Parquet status: `{tx_stats['event_parquet_status']}`",
        ]
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="P3 finance DWD build.")
    parser.add_argument("--config", default="config/finance_bigdata.local.yaml")
    args = parser.parse_args()

    config = load_config(args.config)
    paths = configured_paths(config)
    write_parquet = bool(config["processing"].get("write_parquet_if_available", True))
    run_dir = timestamped_run_dir(paths["output_dir"], "p3_dwd_build")

    steps: list[dict[str, Any]] = []
    account_numbers, account_stats = write_accounts(paths["account"], run_dir, write_parquet)
    steps.append({"step": "write_accounts", "status": "PASS", "detail": account_stats["csv_path"]})
    tx_stats = write_transactions_and_events(paths["transaction"], run_dir, account_numbers, write_parquet)
    steps.append({"step": "write_transactions_and_events", "status": "PASS", "detail": tx_stats["transaction_csv_path"]})
    steps.append({"step": "write_event_long_table", "status": "PASS", "detail": tx_stats["event_csv_path"]})
    steps.append({"step": "account_join_check", "status": "PASS", "detail": "match rates calculated"})

    summary = {
        "run_dir": str(run_dir),
        "dataset": config["project"]["default_dataset"],
        "account": serializable_stats(account_stats),
        "transaction": serializable_stats(tx_stats),
        "status": "PASS",
    }
    write_json(run_dir / "dwd_validation_summary.json", summary)
    write_tsv(run_dir / "steps.tsv", steps, ["step", "status", "detail"])
    write_tsv(
        run_dir / "dwd_summary.tsv",
        [
            {"metric": "account_rows", "value": account_stats["row_count"]},
            {"metric": "unique_account_count", "value": account_stats["unique_account_count"]},
            {"metric": "duplicate_account_number_count", "value": account_stats["duplicate_account_number_count"]},
            {"metric": "transaction_rows", "value": tx_stats["transaction_row_count"]},
            {"metric": "event_rows", "value": tx_stats["event_row_count"]},
            {"metric": "from_account_match_rate", "value": f"{tx_stats['from_account_match_rate']:.8f}"},
            {"metric": "to_account_match_rate", "value": f"{tx_stats['to_account_match_rate']:.8f}"},
            {"metric": "cross_bank_count", "value": tx_stats["cross_bank_count"]},
            {"metric": "cross_currency_count", "value": tx_stats["cross_currency_count"]},
        ],
        ["metric", "value"],
    )
    write_text(run_dir / "dwd_summary.md", build_report(run_dir, account_stats, tx_stats))

    print(f"P3_RUN_DIR={run_dir}")
    print("P3_STATUS=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
