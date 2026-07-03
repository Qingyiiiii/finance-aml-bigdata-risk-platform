# -*- coding: utf-8 -*-
"""Create P11v2 realtime state samples from P9/P10 feature evidence."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import pandas as pd

from finance_make_scoring_contract_sample import (
    FEATURE_COLUMNS,
    TRANSACTION_COLUMNS,
    risk_candidate_score,
)


CONTRACT_VERSION = "p11v2_realtime_state_contract_v1"
FEATURE_SNAPSHOT_VERSION = "p9_p10_non_leakage_v1"
RUN_ID_PLACEHOLDER = "P11V2_RUN_ID_PLACEHOLDER"


def to_record(row: pd.Series, run_id: str) -> dict[str, Any]:
    """Serialize one joined feature/transaction row into the P11v2 input contract."""
    return {
        "run_id": run_id,
        "contract_version": CONTRACT_VERSION,
        "transaction_id": str(row["transaction_id"]),
        "tx_timestamp": str(row["timestamp"]),
        "transaction_date": str(row["transaction_date"]),
        "transaction_hour": int(row["transaction_hour"]),
        "from_account": str(row["from_account"]),
        "to_account": str(row["to_account"]),
        "amount_paid": float(row["amount_paid"]),
        "log_amount_paid": float(row["log_amount_paid"]),
        "payment_currency": str(row["payment_currency"]),
        "payment_format": str(row["payment_format"]),
        "is_cross_bank": int(row["is_cross_bank"]),
        "is_cross_currency": int(row["is_cross_currency"]),
        "hour_sin": float(row["hour_sin"]),
        "hour_cos": float(row["hour_cos"]),
        "from_total_event_count": int(row["from_total_event_count"]),
        "from_debit_count": int(row["from_debit_count"]),
        "from_credit_count": int(row["from_credit_count"]),
        "from_out_amount": float(row["from_out_amount"]),
        "from_in_amount": float(row["from_in_amount"]),
        "from_max_out_amount": float(row["from_max_out_amount"]),
        "from_counterparty_count": int(row["from_counterparty_count"]),
        "from_cross_bank_event_count": int(row["from_cross_bank_event_count"]),
        "from_cross_currency_event_count": int(row["from_cross_currency_event_count"]),
        "from_out_in_ratio": float(row["from_out_in_ratio"]),
        "from_debit_credit_ratio": float(row["from_debit_credit_ratio"]),
        "observed_is_laundering": int(row["is_laundering"]),
        "split": str(row["split"]),
        "feature_snapshot_version": FEATURE_SNAPSHOT_VERSION,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Create P11v2 realtime state JSONL sample.")
    parser.add_argument("--features", required=True)
    parser.add_argument("--transactions", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--rows", type=int, default=10000)
    parser.add_argument("--candidate-share", type=float, default=0.8)
    parser.add_argument("--positive-rows", type=int, default=200)
    parser.add_argument("--random-state", type=int, default=20260702)
    parser.add_argument("--run-id", default=RUN_ID_PLACEHOLDER)
    args = parser.parse_args()

    feature_path = Path(args.features)
    transaction_path = Path(args.transactions)
    output_path = Path(args.output)
    summary_path = Path(args.summary)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.parent.mkdir(parents=True, exist_ok=True)

    features = pd.read_parquet(feature_path, columns=FEATURE_COLUMNS)
    transactions = pd.read_parquet(transaction_path, columns=TRANSACTION_COLUMNS)
    df = features.merge(transactions, on="transaction_id", how="inner")
    df["_candidate_score"] = risk_candidate_score(df)

    target_rows = min(args.rows, len(df))
    selected_parts: list[pd.DataFrame] = []
    selected_indexes: set[Any] = set()

    positives = df[df["is_laundering"] == 1]
    positive_sample_n = min(args.positive_rows, target_rows, len(positives))
    if positive_sample_n > 0:
        positive_sample = positives.sample(n=positive_sample_n, random_state=args.random_state)
        selected_parts.append(positive_sample)
        selected_indexes.update(positive_sample.index.tolist())

    remaining_pool = df.drop(index=list(selected_indexes), errors="ignore")
    candidate_target = min(int(target_rows * args.candidate_share), target_rows - len(selected_indexes))
    candidates = remaining_pool[remaining_pool["_candidate_score"] >= 30]
    candidate_sample_n = min(candidate_target, len(candidates))
    if candidate_sample_n > 0:
        candidate_sample = candidates.sample(n=candidate_sample_n, random_state=args.random_state)
        selected_parts.append(candidate_sample)
        selected_indexes.update(candidate_sample.index.tolist())

    remaining = target_rows - len(selected_indexes)
    if remaining > 0:
        non_candidate_pool = df.drop(index=list(selected_indexes), errors="ignore")
        non_candidate_pool = non_candidate_pool[non_candidate_pool["_candidate_score"] < 30]
        non_candidate_sample_n = min(remaining, len(non_candidate_pool))
        if non_candidate_sample_n > 0:
            non_candidate_sample = non_candidate_pool.sample(n=non_candidate_sample_n, random_state=args.random_state)
            selected_parts.append(non_candidate_sample)
            selected_indexes.update(non_candidate_sample.index.tolist())

    if len(selected_indexes) < target_rows:
        filler_pool = df.drop(index=list(selected_indexes), errors="ignore")
        filler = filler_pool.sample(n=target_rows - len(selected_indexes), random_state=args.random_state)
        selected_parts.append(filler)

    sample = pd.concat(selected_parts, ignore_index=True)
    sample = sample.sample(frac=1.0, random_state=args.random_state).reset_index(drop=True)

    with output_path.open("w", encoding="utf-8", newline="\n") as fh:
        for _, row in sample.iterrows():
            fh.write(json.dumps(to_record(row, args.run_id), ensure_ascii=False, separators=(",", ":")) + "\n")

    summary_rows = [
        ("contract_version", CONTRACT_VERSION),
        ("feature_snapshot_version", FEATURE_SNAPSHOT_VERSION),
        ("source_feature_rows", len(features)),
        ("joined_rows", len(df)),
        ("rows_written", len(sample)),
        ("candidate_rows_available", len(candidates)),
        ("candidate_rows_written", int((sample["_candidate_score"] >= 30).sum())),
        ("non_candidate_rows_written", int((sample["_candidate_score"] < 30).sum())),
        ("positive_rows_target", args.positive_rows),
        ("observed_laundering_rows_written", int(sample["is_laundering"].sum())),
        ("random_state", args.random_state),
        ("run_id", args.run_id),
        ("features", str(feature_path)),
        ("transactions", str(transaction_path)),
        ("output", str(output_path)),
    ]
    with summary_path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write("metric\tvalue\n")
        for key, value in summary_rows:
            fh.write(f"{key}\t{value}\n")

    print(f"P11V2_SAMPLE={output_path}")
    print(f"P11V2_ROWS_WRITTEN={len(sample)}")
    print(f"P11V2_CANDIDATE_ROWS={int((sample['_candidate_score'] >= 30).sum())}")
    return 0 if len(sample) == target_rows else 2


if __name__ == "__main__":
    raise SystemExit(main())
