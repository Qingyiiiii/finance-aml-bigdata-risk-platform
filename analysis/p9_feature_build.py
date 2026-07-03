# -*- coding: utf-8 -*-
"""Build the P9 non-leakage feature dataset for finance AML baseline modeling."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.model_selection import train_test_split

from p9_utils import project_path, write_text, write_tsv


DEFAULT_TRANSACTION_PARQUET = (
    "data/finance_bigdata/runs/p3_dwd_build_20260609_203822/dwd_finance_transactions.parquet"
)
DEFAULT_ACCOUNT_FEATURES = (
    "data/finance_bigdata/runs/p4_dws_risk_kpi_20260609_204441/dws_account_risk_features.parquet"
)


def main() -> int:
    """Build a supervised-learning feature table from accepted P3/P4 evidence."""
    parser = argparse.ArgumentParser(description="P9 feature dataset builder.")
    parser.add_argument("--transactions", default=DEFAULT_TRANSACTION_PARQUET)
    parser.add_argument("--account-features", default=DEFAULT_ACCOUNT_FEATURES)
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--negative-sample", type=int, default=200000)
    parser.add_argument("--random-state", type=int, default=20260609)
    args = parser.parse_args()

    run_dir = project_path(args.run_dir)
    tx_path = project_path(args.transactions)
    account_path = project_path(args.account_features)

    tx_columns = [
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
    account_columns = [
        "account_number",
        "total_event_count",
        "debit_count",
        "credit_count",
        "out_amount",
        "in_amount",
        "max_out_amount",
        "counterparty_count",
        "cross_bank_event_count",
        "cross_currency_event_count",
    ]
    tx = pd.read_parquet(tx_path, columns=tx_columns)
    tx["is_laundering"] = tx["is_laundering"].astype(int)
    positives = tx[tx["is_laundering"] == 1]
    negatives = tx[tx["is_laundering"] == 0]
    sample_n = min(args.negative_sample, len(negatives))
    sampled_negatives = negatives.sample(n=sample_n, random_state=args.random_state)
    dataset = pd.concat([positives, sampled_negatives], ignore_index=True)
    dataset = dataset.sort_values(["transaction_date", "transaction_hour", "transaction_id"]).reset_index(drop=True)

    account = pd.read_parquet(account_path, columns=account_columns)
    prefix_map = {
        "account_number": "from_account",
        "total_event_count": "from_total_event_count",
        "debit_count": "from_debit_count",
        "credit_count": "from_credit_count",
        "out_amount": "from_out_amount",
        "in_amount": "from_in_amount",
        "max_out_amount": "from_max_out_amount",
        "counterparty_count": "from_counterparty_count",
        "cross_bank_event_count": "from_cross_bank_event_count",
        "cross_currency_event_count": "from_cross_currency_event_count",
    }
    from_account = account.rename(columns=prefix_map)
    dataset = dataset.merge(from_account, on="from_account", how="left")

    dataset["log_amount_paid"] = np.log1p(dataset["amount_paid"].astype(float))
    dataset["hour_sin"] = np.sin(2 * np.pi * dataset["transaction_hour"].astype(float) / 24)
    dataset["hour_cos"] = np.cos(2 * np.pi * dataset["transaction_hour"].astype(float) / 24)

    numeric_defaults = {
        "from_total_event_count": 0,
        "from_debit_count": 0,
        "from_credit_count": 0,
        "from_out_amount": 0.0,
        "from_in_amount": 0.0,
        "from_max_out_amount": 0.0,
        "from_counterparty_count": 0,
        "from_cross_bank_event_count": 0,
        "from_cross_currency_event_count": 0,
    }
    for column, value in numeric_defaults.items():
        dataset[column] = dataset[column].fillna(value)
    dataset["from_out_in_ratio"] = dataset["from_out_amount"] / (dataset["from_in_amount"].abs() + 1.0)
    dataset["from_debit_credit_ratio"] = dataset["from_debit_count"] / (dataset["from_credit_count"].abs() + 1.0)
    dataset["split"] = "train"
    _, test_index = train_test_split(
        dataset.index,
        test_size=0.25,
        random_state=args.random_state,
        stratify=dataset["is_laundering"],
    )
    dataset.loc[test_index, "split"] = "test"
    split_strategy = "stratified_random_75_25"

    feature_columns = [
        "transaction_id",
        "transaction_date",
        "split",
        "transaction_hour",
        "amount_paid",
        "log_amount_paid",
        "payment_currency",
        "payment_format",
        "is_cross_bank",
        "is_cross_currency",
        "hour_sin",
        "hour_cos",
        "from_total_event_count",
        "from_debit_count",
        "from_credit_count",
        "from_out_amount",
        "from_in_amount",
        "from_max_out_amount",
        "from_counterparty_count",
        "from_cross_bank_event_count",
        "from_cross_currency_event_count",
        "from_out_in_ratio",
        "from_debit_credit_ratio",
        "is_laundering",
    ]
    feature_df = dataset[feature_columns]
    feature_path = run_dir / "feature_dataset.parquet"
    feature_df.to_parquet(feature_path, index=False)

    split_rows = [
        {
            "split": "train",
            "rows": int((feature_df["split"] == "train").sum()),
            "positive_rows": int(feature_df.loc[feature_df["split"] == "train", "is_laundering"].sum()),
            "strategy": split_strategy,
        },
        {
            "split": "test",
            "rows": int((feature_df["split"] == "test").sum()),
            "positive_rows": int(feature_df.loc[feature_df["split"] == "test", "is_laundering"].sum()),
            "strategy": split_strategy,
        },
    ]
    write_tsv(run_dir / "train_test_split_summary.tsv", split_rows, ["split", "rows", "positive_rows", "strategy"])

    summary_rows = [
        {"metric": "source_transaction_rows", "value": len(tx)},
        {"metric": "source_positive_rows", "value": int(tx["is_laundering"].sum())},
        {"metric": "feature_rows", "value": len(feature_df)},
        {"metric": "feature_positive_rows", "value": int(feature_df["is_laundering"].sum())},
        {"metric": "feature_negative_rows", "value": int((feature_df["is_laundering"] == 0).sum())},
        {"metric": "negative_sample_target", "value": args.negative_sample},
        {"metric": "random_state", "value": args.random_state},
        {"metric": "feature_path", "value": str(feature_path)},
        {"metric": "split_strategy", "value": split_strategy},
    ]
    write_tsv(run_dir / "feature_dataset_summary.tsv", summary_rows, ["metric", "value"])

    schema_lines = [
        "# P9 Feature Schema",
        "",
        "| Column | Role |",
        "| --- | --- |",
    ]
    for column in feature_columns:
        role = "target" if column == "is_laundering" else "feature_or_id"
        if column in {"transaction_id", "transaction_date"}:
            role = "id_or_split"
        if column == "split":
            role = "split"
        schema_lines.append(f"| {column} | {role} |")
    write_text(run_dir / "feature_schema.md", "\n".join(schema_lines))
    write_text(
        run_dir / "feature_build_summary.md",
        f"""# P9 Feature Build Summary

- Feature path: `{feature_path}`
- Feature rows: `{len(feature_df)}`
- Positive rows: `{int(feature_df['is_laundering'].sum())}`
- Negative rows: `{int((feature_df['is_laundering'] == 0).sum())}`
- Split strategy: `{split_strategy}`

The feature dataset uses all laundering rows and a reproducible sample of non-laundering rows. Label-derived account features are excluded from the modeling table.
""",
    )
    print("P9_FEATURE_STATUS=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
