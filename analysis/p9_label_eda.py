# -*- coding: utf-8 -*-
"""Generate P9 label distribution and EDA evidence for finance_bigdata."""
from __future__ import annotations

import argparse
import math
from pathlib import Path

import pandas as pd

from p9_utils import project_path, write_text, write_tsv


DEFAULT_TRANSACTION_PARQUET = (
    "data/finance_bigdata/runs/p3_dwd_build_20260609_203822/dwd_finance_transactions.parquet"
)
DEFAULT_PAYMENT_KPI = (
    "data/finance_bigdata/runs/p4_dws_risk_kpi_20260609_204441/dws_payment_format_kpi.csv"
)


def amount_bins(df: pd.DataFrame) -> list[dict[str, object]]:
    """Summarize laundering-label rate by amount bands."""
    bins = [0, 100, 1000, 10000, 100000, 1000000, 10000000, math.inf]
    labels = ["0-100", "100-1k", "1k-10k", "10k-100k", "100k-1m", "1m-10m", "10m+"]
    tmp = df[["amount_paid", "is_laundering"]].copy()
    tmp["amount_bin"] = pd.cut(tmp["amount_paid"], bins=bins, labels=labels, include_lowest=True, right=False)
    grouped = tmp.groupby("amount_bin", observed=False).agg(
        transaction_count=("is_laundering", "size"),
        laundering_count=("is_laundering", "sum"),
    )
    grouped["laundering_rate"] = grouped["laundering_count"] / grouped["transaction_count"]
    rows = grouped.reset_index()
    rows["amount_bin"] = rows["amount_bin"].astype(str)
    rows["laundering_rate"] = rows["laundering_rate"].fillna(0)
    return rows.to_dict("records")


def group_rate(df: pd.DataFrame, column: str) -> list[dict[str, object]]:
    """Calculate label rate for one categorical dimension."""
    grouped = df.groupby(column, dropna=False).agg(
        transaction_count=("is_laundering", "size"),
        laundering_count=("is_laundering", "sum"),
        avg_amount_paid=("amount_paid", "mean"),
        max_amount_paid=("amount_paid", "max"),
    )
    grouped["laundering_rate"] = grouped["laundering_count"] / grouped["transaction_count"]
    return grouped.reset_index().sort_values("transaction_count", ascending=False).to_dict("records")


def main() -> int:
    """Write P9 label distribution and EDA artifacts."""
    parser = argparse.ArgumentParser(description="P9 label and EDA metrics.")
    parser.add_argument("--transactions", default=DEFAULT_TRANSACTION_PARQUET)
    parser.add_argument("--payment-kpi", default=DEFAULT_PAYMENT_KPI)
    parser.add_argument("--run-dir", required=True)
    args = parser.parse_args()

    run_dir = project_path(args.run_dir)
    tx_path = project_path(args.transactions)
    columns = [
        "transaction_id",
        "transaction_date",
        "transaction_hour",
        "from_account",
        "to_account",
        "amount_paid",
        "payment_currency",
        "payment_format",
        "is_laundering",
        "is_cross_bank",
        "is_cross_currency",
    ]
    df = pd.read_parquet(tx_path, columns=columns)
    df["is_laundering"] = df["is_laundering"].astype(int)
    df["is_cross_bank"] = df["is_cross_bank"].astype(int)
    df["is_cross_currency"] = df["is_cross_currency"].astype(int)

    total = int(len(df))
    positive = int(df["is_laundering"].sum())
    negative = total - positive
    positive_rate = positive / total if total else 0

    label_rows = [
        {"label": 0, "count": negative, "rate": negative / total if total else 0},
        {"label": 1, "count": positive, "rate": positive_rate},
    ]
    write_tsv(run_dir / "label_distribution.tsv", label_rows, ["label", "count", "rate"])

    metric_rows = [
        {"metric": "transaction_rows", "value": total},
        {"metric": "laundering_rows", "value": positive},
        {"metric": "non_laundering_rows", "value": negative},
        {"metric": "laundering_rate", "value": f"{positive_rate:.10f}"},
        {"metric": "distinct_from_accounts", "value": int(df["from_account"].nunique())},
        {"metric": "distinct_to_accounts", "value": int(df["to_account"].nunique())},
        {"metric": "cross_bank_rows", "value": int(df["is_cross_bank"].sum())},
        {"metric": "cross_currency_rows", "value": int(df["is_cross_currency"].sum())},
        {"metric": "amount_paid_min", "value": float(df["amount_paid"].min())},
        {"metric": "amount_paid_p50", "value": float(df["amount_paid"].quantile(0.5))},
        {"metric": "amount_paid_p95", "value": float(df["amount_paid"].quantile(0.95))},
        {"metric": "amount_paid_p99", "value": float(df["amount_paid"].quantile(0.99))},
        {"metric": "amount_paid_max", "value": float(df["amount_paid"].max())},
    ]
    write_tsv(run_dir / "eda_metrics.tsv", metric_rows, ["metric", "value"])

    payment_rows = group_rate(df, "payment_format")
    write_tsv(
        run_dir / "payment_format_label_distribution.tsv",
        payment_rows,
        ["payment_format", "transaction_count", "laundering_count", "avg_amount_paid", "max_amount_paid", "laundering_rate"],
    )
    currency_rows = group_rate(df, "payment_currency")
    write_tsv(
        run_dir / "payment_currency_label_distribution.tsv",
        currency_rows,
        ["payment_currency", "transaction_count", "laundering_count", "avg_amount_paid", "max_amount_paid", "laundering_rate"],
    )
    write_tsv(
        run_dir / "amount_bin_label_distribution.tsv",
        amount_bins(df),
        ["amount_bin", "transaction_count", "laundering_count", "laundering_rate"],
    )
    cross_rows = []
    for column in ["is_cross_bank", "is_cross_currency", "transaction_hour"]:
        for row in group_rate(df, column):
            row["dimension"] = column
            row["dimension_value"] = row.pop(column)
            cross_rows.append(row)
    write_tsv(
        run_dir / "eda_dimension_label_distribution.tsv",
        cross_rows,
        ["dimension", "dimension_value", "transaction_count", "laundering_count", "avg_amount_paid", "max_amount_paid", "laundering_rate"],
    )

    payment_kpi_path = project_path(args.payment_kpi)
    if payment_kpi_path.exists():
        pd.read_csv(payment_kpi_path).to_csv(run_dir / "source_payment_format_kpi_copy.tsv", sep="\t", index=False)

    summary = f"""# P9 Label And EDA Summary

- Source transactions: `{tx_path}`
- Transaction rows: `{total}`
- Laundering rows: `{positive}`
- Laundering rate: `{positive_rate:.6%}`
- Distinct from accounts: `{int(df['from_account'].nunique())}`
- Distinct to accounts: `{int(df['to_account'].nunique())}`
- Cross-bank rows: `{int(df['is_cross_bank'].sum())}`
- Cross-currency rows: `{int(df['is_cross_currency'].sum())}`


Accuracy alone is not a useful target because the positive class is rare. P9 model evaluation prioritizes precision, recall, F1 and PR-AUC.
"""
    write_text(run_dir / "eda_summary.md", summary)
    print(f"P9_EDA_STATUS=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
