# -*- coding: utf-8 -*-
"""Build P4 DWS risk KPI tables from P3 DWD finance outputs."""
from __future__ import annotations

import argparse
import csv
import math
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from finance_utils import (
    OptionalParquetWriter,
    configured_paths,
    load_config,
    parse_float,
    timestamped_run_dir,
    write_json,
    write_text,
    write_tsv,
)


DWS_MINUTE_COLUMNS = [
    "transaction_minute",
    "payment_format",
    "transaction_count",
    "laundering_count",
    "laundering_rate",
    "total_amount_paid",
    "distinct_account_count",
]

DWS_ACCOUNT_COLUMNS = [
    "account_number",
    "total_event_count",
    "debit_count",
    "credit_count",
    "out_amount",
    "in_amount",
    "net_amount",
    "max_out_amount",
    "counterparty_count",
    "laundering_event_count",
    "cross_bank_event_count",
    "cross_currency_event_count",
    "risk_score_rule",
]

DWS_PAYMENT_COLUMNS = [
    "payment_format",
    "transaction_count",
    "laundering_count",
    "laundering_rate",
    "total_amount_paid",
    "avg_amount_paid",
    "max_amount_paid",
]

DWS_LARGE_CANDIDATE_COLUMNS = [
    "transaction_id",
    "timestamp",
    "transaction_minute",
    "from_bank",
    "from_account",
    "to_bank",
    "to_account",
    "amount_paid",
    "payment_currency",
    "payment_format",
    "is_laundering",
    "is_cross_bank",
    "is_cross_currency",
    "rule_hits",
]


def find_latest_dwd_run(output_dir: Path) -> Path:
    """Find the newest P3 DWD run when the caller does not pass one explicitly."""
    runs_dir = output_dir / "runs"
    candidates = sorted(runs_dir.glob("p3_dwd_build_*"))
    if not candidates:
        raise FileNotFoundError(f"No p3_dwd_build_* run directory found under {runs_dir}")
    return candidates[-1]


def truthy_int(value: str) -> int:
    text = str(value).strip()
    return 1 if text in {"1", "true", "True"} else 0


def quantile(sorted_values: list[float], q: float) -> float:
    """Compute a simple quantile over a pre-sorted numeric list."""
    if not sorted_values:
        return 0.0
    if q <= 0:
        return sorted_values[0]
    if q >= 1:
        return sorted_values[-1]
    pos = (len(sorted_values) - 1) * q
    lower = math.floor(pos)
    upper = math.ceil(pos)
    if lower == upper:
        return sorted_values[int(pos)]
    weight = pos - lower
    return sorted_values[lower] * (1 - weight) + sorted_values[upper] * weight


def first_pass(transactions_csv: Path) -> dict[str, Any]:
    """Scan DWD transactions once to collect all DWS aggregation state."""
    minute_stats: dict[tuple[str, str], dict[str, Any]] = {}
    account_stats: dict[str, dict[str, Any]] = {}
    payment_stats: dict[str, dict[str, Any]] = {}
    amounts: list[float] = []
    malformed = 0
    row_count = 0
    label_counts: Counter[str] = Counter()

    def get_account(account: str) -> dict[str, Any]:
        if account not in account_stats:
            account_stats[account] = {
                "debit_count": 0,
                "credit_count": 0,
                "out_amount": 0.0,
                "in_amount": 0.0,
                "max_out_amount": 0.0,
                "counterparties": set(),
                "laundering_event_count": 0,
                "cross_bank_event_count": 0,
                "cross_currency_event_count": 0,
            }
        return account_stats[account]

    with transactions_csv.open("r", encoding="utf-8-sig", newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            amount_paid = parse_float(row.get("amount_paid", ""))
            amount_received = parse_float(row.get("amount_received", ""))
            if amount_paid is None or amount_received is None:
                malformed += 1
                continue
            row_count += 1
            amounts.append(amount_paid)
            is_laundering = truthy_int(row.get("is_laundering", "0"))
            is_cross_bank = truthy_int(row.get("is_cross_bank", "0"))
            is_cross_currency = truthy_int(row.get("is_cross_currency", "0"))
            label_counts[str(is_laundering)] += 1

            minute_key = (row["transaction_minute"], row["payment_format"])
            if minute_key not in minute_stats:
                minute_stats[minute_key] = {
                    "transaction_count": 0,
                    "laundering_count": 0,
                    "total_amount_paid": 0.0,
                    "accounts": set(),
                }
            minute = minute_stats[minute_key]
            minute["transaction_count"] += 1
            minute["laundering_count"] += is_laundering
            minute["total_amount_paid"] += amount_paid
            minute["accounts"].add(row["from_account"])
            minute["accounts"].add(row["to_account"])

            payment_format = row["payment_format"]
            if payment_format not in payment_stats:
                payment_stats[payment_format] = {
                    "transaction_count": 0,
                    "laundering_count": 0,
                    "total_amount_paid": 0.0,
                    "max_amount_paid": 0.0,
                }
            payment = payment_stats[payment_format]
            payment["transaction_count"] += 1
            payment["laundering_count"] += is_laundering
            payment["total_amount_paid"] += amount_paid
            payment["max_amount_paid"] = max(payment["max_amount_paid"], amount_paid)

            debit = get_account(row["from_account"])
            debit["debit_count"] += 1
            debit["out_amount"] += amount_paid
            debit["max_out_amount"] = max(debit["max_out_amount"], amount_paid)
            debit["counterparties"].add(row["to_account"])
            debit["laundering_event_count"] += is_laundering
            debit["cross_bank_event_count"] += is_cross_bank
            debit["cross_currency_event_count"] += is_cross_currency

            credit = get_account(row["to_account"])
            credit["credit_count"] += 1
            credit["in_amount"] += amount_received
            credit["counterparties"].add(row["from_account"])
            credit["laundering_event_count"] += is_laundering
            credit["cross_bank_event_count"] += is_cross_bank
            credit["cross_currency_event_count"] += is_cross_currency

    amounts.sort()
    return {
        "row_count": row_count,
        "malformed_count": malformed,
        "label_counts": dict(label_counts),
        "amounts": amounts,
        "minute_stats": minute_stats,
        "account_stats": account_stats,
        "payment_stats": payment_stats,
    }


def write_minute_kpi(run_dir: Path, stats: dict[tuple[str, str], dict[str, Any]], write_parquet: bool) -> dict[str, Any]:
    output_csv = run_dir / "dws_minute_transaction_kpi.csv"
    output_parquet = run_dir / "dws_minute_transaction_kpi.parquet"
    parquet_writer = OptionalParquetWriter(output_parquet, enabled=write_parquet)
    rows = 0
    with output_csv.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=DWS_MINUTE_COLUMNS, lineterminator="\n")
        writer.writeheader()
        for (minute, payment_format), item in sorted(stats.items()):
            count = item["transaction_count"]
            row = {
                "transaction_minute": minute,
                "payment_format": payment_format,
                "transaction_count": count,
                "laundering_count": item["laundering_count"],
                "laundering_rate": item["laundering_count"] / count if count else 0.0,
                "total_amount_paid": item["total_amount_paid"],
                "distinct_account_count": len(item["accounts"]),
            }
            writer.writerow(row)
            parquet_writer.write(row)
            rows += 1
    parquet_writer.close()
    return {
        "csv_path": str(output_csv),
        "parquet_path": str(output_parquet) if parquet_writer.rows_written else "",
        "parquet_status": parquet_writer.detail,
        "row_count": rows,
    }


def account_risk_score(item: dict[str, Any], large_threshold: float) -> int:
    """Calculate an explainable account-level rule score for DWS features."""
    score = 0
    if item["laundering_event_count"] > 0:
        score += 3
    if item["max_out_amount"] >= large_threshold:
        score += 2
    if len(item["counterparties"]) >= 20:
        score += 1
    if item["cross_currency_event_count"] >= 5:
        score += 1
    return score


def write_account_features(
    run_dir: Path,
    stats: dict[str, dict[str, Any]],
    large_threshold: float,
    write_parquet: bool,
) -> dict[str, Any]:
    output_csv = run_dir / "dws_account_risk_features.csv"
    output_parquet = run_dir / "dws_account_risk_features.parquet"
    parquet_writer = OptionalParquetWriter(output_parquet, enabled=write_parquet)
    rows = 0
    with output_csv.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=DWS_ACCOUNT_COLUMNS, lineterminator="\n")
        writer.writeheader()
        for account, item in sorted(stats.items()):
            debit_count = item["debit_count"]
            credit_count = item["credit_count"]
            row = {
                "account_number": account,
                "total_event_count": debit_count + credit_count,
                "debit_count": debit_count,
                "credit_count": credit_count,
                "out_amount": item["out_amount"],
                "in_amount": item["in_amount"],
                "net_amount": item["in_amount"] - item["out_amount"],
                "max_out_amount": item["max_out_amount"],
                "counterparty_count": len(item["counterparties"]),
                "laundering_event_count": item["laundering_event_count"],
                "cross_bank_event_count": item["cross_bank_event_count"],
                "cross_currency_event_count": item["cross_currency_event_count"],
                "risk_score_rule": account_risk_score(item, large_threshold),
            }
            writer.writerow(row)
            parquet_writer.write(row)
            rows += 1
    parquet_writer.close()
    return {
        "csv_path": str(output_csv),
        "parquet_path": str(output_parquet) if parquet_writer.rows_written else "",
        "parquet_status": parquet_writer.detail,
        "row_count": rows,
    }


def write_payment_format_kpi(
    run_dir: Path, stats: dict[str, dict[str, Any]], write_parquet: bool
) -> dict[str, Any]:
    output_csv = run_dir / "dws_payment_format_kpi.csv"
    output_parquet = run_dir / "dws_payment_format_kpi.parquet"
    parquet_writer = OptionalParquetWriter(output_parquet, enabled=write_parquet)
    rows = 0
    with output_csv.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=DWS_PAYMENT_COLUMNS, lineterminator="\n")
        writer.writeheader()
        for payment_format, item in sorted(stats.items()):
            count = item["transaction_count"]
            row = {
                "payment_format": payment_format,
                "transaction_count": count,
                "laundering_count": item["laundering_count"],
                "laundering_rate": item["laundering_count"] / count if count else 0.0,
                "total_amount_paid": item["total_amount_paid"],
                "avg_amount_paid": item["total_amount_paid"] / count if count else 0.0,
                "max_amount_paid": item["max_amount_paid"],
            }
            writer.writerow(row)
            parquet_writer.write(row)
            rows += 1
    parquet_writer.close()
    return {
        "csv_path": str(output_csv),
        "parquet_path": str(output_parquet) if parquet_writer.rows_written else "",
        "parquet_status": parquet_writer.detail,
        "row_count": rows,
    }


def candidate_rule_hits(row: dict[str, str], amount: float, quantile_threshold: float, absolute_threshold: float) -> list[str]:
    """Return the large-transaction candidate rules hit by one transaction."""
    hits: list[str] = []
    if amount >= quantile_threshold:
        hits.append("amount_ge_q995")
    if amount >= absolute_threshold:
        hits.append("amount_ge_absolute_threshold")
    if (
        truthy_int(row.get("is_cross_bank", "0"))
        and truthy_int(row.get("is_cross_currency", "0"))
        and amount >= quantile_threshold * 0.5
    ):
        hits.append("cross_bank_cross_currency_high_amount")
    return hits


def write_large_candidates(
    transactions_csv: Path,
    run_dir: Path,
    quantile_threshold: float,
    absolute_threshold: float,
    write_parquet: bool,
) -> dict[str, Any]:
    """Write DWS large-transaction candidates and summarize rule coverage."""
    output_csv = run_dir / "dws_large_transaction_candidates.csv"
    output_parquet = run_dir / "dws_large_transaction_candidates.parquet"
    parquet_writer = OptionalParquetWriter(output_parquet, enabled=write_parquet)
    rows = 0
    with transactions_csv.open("r", encoding="utf-8-sig", newline="") as source, output_csv.open(
        "w", encoding="utf-8", newline=""
    ) as target:
        reader = csv.DictReader(source)
        writer = csv.DictWriter(target, fieldnames=DWS_LARGE_CANDIDATE_COLUMNS, lineterminator="\n")
        writer.writeheader()
        for tx in reader:
            amount = parse_float(tx.get("amount_paid", ""))
            if amount is None:
                continue
            hits = candidate_rule_hits(tx, amount, quantile_threshold, absolute_threshold)
            if not hits:
                continue
            row = {
                "transaction_id": tx["transaction_id"],
                "timestamp": tx["timestamp"],
                "transaction_minute": tx["transaction_minute"],
                "from_bank": tx["from_bank"],
                "from_account": tx["from_account"],
                "to_bank": tx["to_bank"],
                "to_account": tx["to_account"],
                "amount_paid": amount,
                "payment_currency": tx["payment_currency"],
                "payment_format": tx["payment_format"],
                "is_laundering": truthy_int(tx["is_laundering"]),
                "is_cross_bank": truthy_int(tx["is_cross_bank"]),
                "is_cross_currency": truthy_int(tx["is_cross_currency"]),
                "rule_hits": ";".join(hits),
            }
            writer.writerow(row)
            parquet_writer.write(row)
            rows += 1
    parquet_writer.close()
    return {
        "csv_path": str(output_csv),
        "parquet_path": str(output_parquet) if parquet_writer.rows_written else "",
        "parquet_status": parquet_writer.detail,
        "row_count": rows,
    }


def build_report(run_dir: Path, dwd_run_dir: Path, summary: dict[str, Any]) -> str:
    return "\n".join(
        [
            "# P4 DWS Risk KPI Report",
            "",
            f"- Run dir: `{run_dir}`",
            f"- Source DWD run dir: `{dwd_run_dir}`",
            f"- Source transaction rows: `{summary['source_transaction_rows']}`",
            f"- Minute KPI rows: `{summary['minute_kpi']['row_count']}`",
            f"- Account feature rows: `{summary['account_features']['row_count']}`",
            f"- Payment format KPI rows: `{summary['payment_format_kpi']['row_count']}`",
            f"- Large transaction candidates: `{summary['large_candidates']['row_count']}`",
            f"- Amount q995 threshold: `{summary['large_transaction_quantile_threshold']}`",
            f"- Absolute threshold: `{summary['large_transaction_absolute_threshold']}`",
            f"- Status: `{summary['status']}`",
        ]
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="P4 finance DWS risk KPI build.")
    parser.add_argument("--config", default="config/finance_bigdata.local.yaml")
    parser.add_argument("--dwd-run-dir", default="")
    args = parser.parse_args()

    config = load_config(args.config)
    paths = configured_paths(config)
    write_parquet = bool(config["processing"].get("write_parquet_if_available", True))
    q = float(config["processing"].get("large_transaction_quantile", 0.995))
    absolute_threshold = float(config["processing"].get("large_transaction_min_amount", 1000000))

    dwd_run_dir = Path(args.dwd_run_dir) if args.dwd_run_dir else find_latest_dwd_run(paths["output_dir"])
    transactions_csv = dwd_run_dir / "dwd_finance_transactions.csv"
    if not transactions_csv.exists():
        raise FileNotFoundError(f"DWD transaction file not found: {transactions_csv}")

    run_dir = timestamped_run_dir(paths["output_dir"], "p4_dws_risk_kpi")
    steps: list[dict[str, Any]] = []
    aggregates = first_pass(transactions_csv)
    steps.append({"step": "aggregate_dwd_transactions", "status": "PASS", "detail": str(transactions_csv)})

    q_threshold = quantile(aggregates["amounts"], q)
    minute_result = write_minute_kpi(run_dir, aggregates["minute_stats"], write_parquet)
    steps.append({"step": "write_minute_transaction_kpi", "status": "PASS", "detail": minute_result["csv_path"]})
    account_result = write_account_features(run_dir, aggregates["account_stats"], q_threshold, write_parquet)
    steps.append({"step": "write_account_risk_features", "status": "PASS", "detail": account_result["csv_path"]})
    payment_result = write_payment_format_kpi(run_dir, aggregates["payment_stats"], write_parquet)
    steps.append({"step": "write_payment_format_kpi", "status": "PASS", "detail": payment_result["csv_path"]})
    candidate_result = write_large_candidates(
        transactions_csv, run_dir, q_threshold, absolute_threshold, write_parquet
    )
    steps.append({"step": "write_large_transaction_candidates", "status": "PASS", "detail": candidate_result["csv_path"]})

    summary = {
        "run_dir": str(run_dir),
        "source_dwd_run_dir": str(dwd_run_dir),
        "source_transaction_rows": aggregates["row_count"],
        "source_malformed_rows": aggregates["malformed_count"],
        "label_counts": aggregates["label_counts"],
        "large_transaction_quantile": q,
        "large_transaction_quantile_threshold": q_threshold,
        "large_transaction_absolute_threshold": absolute_threshold,
        "minute_kpi": minute_result,
        "account_features": account_result,
        "payment_format_kpi": payment_result,
        "large_candidates": candidate_result,
        "status": "PASS",
    }
    write_json(run_dir / "dws_validation_summary.json", summary)
    write_tsv(run_dir / "steps.tsv", steps, ["step", "status", "detail"])
    write_tsv(
        run_dir / "dws_summary.tsv",
        [
            {"metric": "source_transaction_rows", "value": aggregates["row_count"]},
            {"metric": "minute_kpi_rows", "value": minute_result["row_count"]},
            {"metric": "account_feature_rows", "value": account_result["row_count"]},
            {"metric": "payment_format_kpi_rows", "value": payment_result["row_count"]},
            {"metric": "large_candidate_rows", "value": candidate_result["row_count"]},
            {"metric": "large_transaction_q995_threshold", "value": f"{q_threshold:.6f}"},
            {"metric": "absolute_threshold", "value": f"{absolute_threshold:.6f}"},
        ],
        ["metric", "value"],
    )
    write_text(run_dir / "dws_summary.md", build_report(run_dir, dwd_run_dir, summary))

    print(f"P4_RUN_DIR={run_dir}")
    print("P4_STATUS=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
