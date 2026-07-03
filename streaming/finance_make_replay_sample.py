# -*- coding: utf-8 -*-
"""Create P6 Kafka replay JSONL samples from DWD finance transactions."""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any


REPLAY_COLUMNS = [
    "run_id",
    "transaction_id",
    "tx_timestamp",
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
]


def parse_float(value: str) -> float:
    """Parse numeric amount fields from DWD CSV rows."""
    return float(str(value).strip().replace(",", ""))


def parse_int(value: str) -> int:
    return int(float(str(value).strip()))


def build_replay_row(raw: dict[str, str], run_id: str) -> dict[str, Any]:
    """Map one DWD transaction row into the P6 Kafka event contract."""
    return {
        "run_id": run_id,
        "transaction_id": raw["transaction_id"],
        "tx_timestamp": raw["timestamp"],
        "transaction_minute": raw["transaction_minute"],
        "from_bank": raw["from_bank"],
        "from_account": raw["from_account"],
        "to_bank": raw["to_bank"],
        "to_account": raw["to_account"],
        "amount_paid": parse_float(raw["amount_paid"]),
        "payment_currency": raw["payment_currency"],
        "payment_format": raw["payment_format"],
        "is_laundering": parse_int(raw["is_laundering"]),
        "is_cross_bank": parse_int(raw["is_cross_bank"]),
        "is_cross_currency": parse_int(raw["is_cross_currency"]),
    }


def is_rule_candidate(row: dict[str, Any], threshold: float) -> bool:
    """Decide whether a transaction should be prioritized in the replay sample."""
    return bool(
        row["is_laundering"] == 1
        or row["amount_paid"] >= threshold
        or row["is_cross_currency"] == 1
    )


def main() -> int:
    """Create a bounded JSONL replay sample for the P6 realtime demo."""
    parser = argparse.ArgumentParser(description="Create a JSONL replay sample for P6 Kafka input.")
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--rows", type=int, default=10000)
    parser.add_argument("--run-id", default="P6_RUN_ID_PLACEHOLDER")
    parser.add_argument("--large-amount-threshold", type=float, default=1000000.0)
    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)
    summary_path = Path(args.summary)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.parent.mkdir(parents=True, exist_ok=True)

    written = 0
    laundering = 0
    large_amount = 0
    cross_bank = 0
    cross_currency = 0
    rule_candidates = 0

    with input_path.open("r", encoding="utf-8-sig", newline="") as source, output_path.open(
        "w", encoding="utf-8", newline="\n"
    ) as target:
        reader = csv.DictReader(source)
        for raw in reader:
            row = build_replay_row(raw, args.run_id)
            target.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
            written += 1
            laundering += int(row["is_laundering"] == 1)
            large_amount += int(row["amount_paid"] >= args.large_amount_threshold)
            cross_bank += int(row["is_cross_bank"] == 1)
            cross_currency += int(row["is_cross_currency"] == 1)
            rule_candidates += int(is_rule_candidate(row, args.large_amount_threshold))
            if written >= args.rows:
                break

    rows = [
        ("rows_written", written),
        ("laundering_rows", laundering),
        ("large_amount_rows", large_amount),
        ("cross_bank_rows", cross_bank),
        ("cross_currency_rows", cross_currency),
        ("rule_candidate_rows", rule_candidates),
        ("large_amount_threshold", args.large_amount_threshold),
        ("run_id", args.run_id),
        ("source", str(input_path)),
        ("output", str(output_path)),
    ]
    with summary_path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write("metric\tvalue\n")
        for key, value in rows:
            fh.write(f"{key}\t{value}\n")

    print(f"REPLAY_SAMPLE={output_path}")
    print(f"ROWS_WRITTEN={written}")
    print(f"RULE_CANDIDATE_ROWS={rule_candidates}")
    return 0 if written == args.rows else 2


if __name__ == "__main__":
    raise SystemExit(main())
