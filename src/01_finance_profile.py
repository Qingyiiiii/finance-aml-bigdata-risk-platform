# -*- coding: utf-8 -*-
"""Profile raw HI-Small finance transaction, account, and pattern files."""
from __future__ import annotations

import argparse
import csv
from collections import Counter
from pathlib import Path
from typing import Any

from finance_utils import (
    TRANSACTION_ODS_COLUMNS,
    configured_paths,
    format_top_counter,
    load_config,
    normalize_transaction_row,
    parse_float,
    timestamped_run_dir,
    write_json,
    write_text,
    write_tsv,
)


def profile_transactions(path: Path) -> dict[str, Any]:
    """Profile the raw transaction file without materializing it in memory."""
    stats: dict[str, Any] = {
        "file": str(path),
        "row_count": 0,
        "malformed_count": 0,
        "min_timestamp": "",
        "max_timestamp": "",
        "label_counts": Counter(),
        "payment_format_counts": Counter(),
        "payment_currency_counts": Counter(),
        "receiving_currency_counts": Counter(),
        "from_bank_count": 0,
        "to_bank_count": 0,
        "account_count": 0,
        "amount_paid_min": None,
        "amount_paid_max": None,
        "amount_paid_sum": 0.0,
        "amount_received_sum": 0.0,
        "invalid_amount_count": 0,
    }
    from_banks: set[str] = set()
    to_banks: set[str] = set()
    accounts: set[str] = set()

    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        reader = csv.reader(fh)
        next(reader)
        for row in reader:
            if len(row) != len(TRANSACTION_ODS_COLUMNS):
                stats["malformed_count"] += 1
                continue
            tx = normalize_transaction_row(row)
            stats["row_count"] += 1

            ts = tx["timestamp"]
            if ts:
                if not stats["min_timestamp"] or ts < stats["min_timestamp"]:
                    stats["min_timestamp"] = ts
                if not stats["max_timestamp"] or ts > stats["max_timestamp"]:
                    stats["max_timestamp"] = ts

            stats["label_counts"][tx["is_laundering"]] += 1
            stats["payment_format_counts"][tx["payment_format"]] += 1
            stats["payment_currency_counts"][tx["payment_currency"]] += 1
            stats["receiving_currency_counts"][tx["receiving_currency"]] += 1
            from_banks.add(tx["from_bank"])
            to_banks.add(tx["to_bank"])
            accounts.add(tx["from_account"])
            accounts.add(tx["to_account"])

            amount_paid = parse_float(tx["amount_paid"])
            amount_received = parse_float(tx["amount_received"])
            if amount_paid is None or amount_received is None:
                stats["invalid_amount_count"] += 1
                continue
            stats["amount_paid_sum"] += amount_paid
            stats["amount_received_sum"] += amount_received
            if stats["amount_paid_min"] is None or amount_paid < stats["amount_paid_min"]:
                stats["amount_paid_min"] = amount_paid
            if stats["amount_paid_max"] is None or amount_paid > stats["amount_paid_max"]:
                stats["amount_paid_max"] = amount_paid

    stats["from_bank_count"] = len(from_banks)
    stats["to_bank_count"] = len(to_banks)
    stats["account_count"] = len(accounts)
    return stats


def profile_accounts(path: Path) -> dict[str, Any]:
    """Profile the raw account dimension file."""
    stats: dict[str, Any] = {
        "file": str(path),
        "row_count": 0,
        "malformed_count": 0,
        "bank_count": 0,
        "account_count": 0,
        "entity_count": 0,
        "top_bank_ids": Counter(),
    }
    bank_ids: set[str] = set()
    account_numbers: set[str] = set()
    entity_ids: set[str] = set()

    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        reader = csv.reader(fh)
        next(reader)
        for row in reader:
            if len(row) != 5:
                stats["malformed_count"] += 1
                continue
            stats["row_count"] += 1
            bank_id = row[1].strip()
            account_number = row[2].strip()
            entity_id = row[3].strip()
            bank_ids.add(bank_id)
            account_numbers.add(account_number)
            entity_ids.add(entity_id)
            stats["top_bank_ids"][bank_id] += 1

    stats["bank_count"] = len(bank_ids)
    stats["account_count"] = len(account_numbers)
    stats["entity_count"] = len(entity_ids)
    return stats


def profile_patterns(path: Path) -> dict[str, Any]:
    """Profile the laundering pattern text file at a coarse evidence level."""
    stats: dict[str, Any] = {
        "file": str(path),
        "line_count": 0,
        "begin_marker_count": 0,
        "end_marker_count": 0,
        "transaction_line_count": 0,
        "other_line_count": 0,
        "label_counts": Counter(),
        "pattern_type_counts": Counter(),
    }

    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        for line in fh:
            stripped = line.strip()
            if not stripped:
                continue
            stats["line_count"] += 1
            if stripped.startswith("BEGIN LAUNDERING ATTEMPT"):
                stats["begin_marker_count"] += 1
                pattern_type = stripped.split(":", 1)[0].replace("BEGIN LAUNDERING ATTEMPT -", "").strip()
                stats["pattern_type_counts"][pattern_type] += 1
                continue
            if stripped.startswith("END LAUNDERING ATTEMPT"):
                stats["end_marker_count"] += 1
                continue

            row = next(csv.reader([stripped]))
            if len(row) == len(TRANSACTION_ODS_COLUMNS) and row[-1].strip() in {"0", "1"}:
                stats["transaction_line_count"] += 1
                stats["label_counts"][row[-1].strip()] += 1
            else:
                stats["other_line_count"] += 1

    return stats


def serializable_profile(profile: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in profile.items():
        if isinstance(value, Counter):
            result[key] = format_top_counter(value, 30)
        else:
            result[key] = value
    return result


def build_markdown(run_dir: Path, transaction: dict[str, Any], account: dict[str, Any], pattern: dict[str, Any]) -> str:
    label_counts = transaction["label_counts"]
    laundering = label_counts.get("1", 0)
    row_count = transaction["row_count"]
    rate = laundering / row_count if row_count else 0
    lines = [
        "# P1 Finance Profile Summary",
        "",
        f"- Run dir: `{run_dir}`",
        f"- Transaction rows: `{row_count}`",
        f"- Transaction malformed rows: `{transaction['malformed_count']}`",
        f"- Time range: `{transaction['min_timestamp']}` to `{transaction['max_timestamp']}`",
        f"- Laundering rows: `{laundering}`",
        f"- Laundering rate: `{rate:.6%}`",
        f"- Distinct accounts in transactions: `{transaction['account_count']}`",
        f"- Account table rows: `{account['row_count']}`",
        f"- Pattern attempts: `{pattern['begin_marker_count']}`",
        f"- Pattern transaction lines: `{pattern['transaction_line_count']}`",
        "",
        "## Top Payment Formats",
        "",
        "| Value | Count |",
        "| --- | ---: |",
    ]
    for item in format_top_counter(transaction["payment_format_counts"], 15):
        lines.append(f"| {item['value']} | {item['count']} |")
    lines.extend(["", "## Top Pattern Types", "", "| Value | Count |", "| --- | ---: |"])
    for item in format_top_counter(pattern["pattern_type_counts"], 15):
        lines.append(f"| {item['value']} | {item['count']} |")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="P1 finance raw data profile.")
    parser.add_argument("--config", default="config/finance_bigdata.local.yaml")
    args = parser.parse_args()

    config = load_config(args.config)
    paths = configured_paths(config)
    run_dir = timestamped_run_dir(paths["output_dir"], "p1_profile")

    transaction = profile_transactions(paths["transaction"])
    account = profile_accounts(paths["account"])
    pattern = profile_patterns(paths["pattern"])

    payload = {
        "transaction": serializable_profile(transaction),
        "account": serializable_profile(account),
        "pattern": serializable_profile(pattern),
    }
    write_json(run_dir / "profile_summary.json", payload)

    metric_rows = [
        {"section": "transaction", "metric": "row_count", "value": transaction["row_count"]},
        {"section": "transaction", "metric": "malformed_count", "value": transaction["malformed_count"]},
        {"section": "transaction", "metric": "min_timestamp", "value": transaction["min_timestamp"]},
        {"section": "transaction", "metric": "max_timestamp", "value": transaction["max_timestamp"]},
        {"section": "transaction", "metric": "distinct_accounts", "value": transaction["account_count"]},
        {"section": "account", "metric": "row_count", "value": account["row_count"]},
        {"section": "account", "metric": "entity_count", "value": account["entity_count"]},
        {"section": "pattern", "metric": "begin_marker_count", "value": pattern["begin_marker_count"]},
        {"section": "pattern", "metric": "transaction_line_count", "value": pattern["transaction_line_count"]},
    ]
    write_tsv(run_dir / "profile_metrics.tsv", metric_rows, ["section", "metric", "value"])
    write_text(run_dir / "profile_summary.md", build_markdown(run_dir, transaction, account, pattern))

    print(f"P1_RUN_DIR={run_dir}")
    print("P1_STATUS=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
