# -*- coding: utf-8 -*-
"""Validate P11 risk events and write contract-compliant events to Redis."""
from __future__ import annotations

import argparse
import json
import socket
from pathlib import Path
from typing import Any


CONTRACT_VERSION = "p11_realtime_scoring_contract_v1"
REQUIRED_FIELDS = {
    "run_id": str,
    "contract_version": str,
    "transaction_id": str,
    "event_time": str,
    "event_account": str,
    "counterparty_account": str,
    "amount_paid": (int, float),
    "payment_currency": str,
    "payment_format": str,
    "feature_snapshot_version": str,
    "risk_score": int,
    "risk_level": str,
    "risk_reasons": str,
    "rule_hits": str,
    "scored_at": str,
}


def encode_command(*parts: str) -> bytes:
    """Encode a Redis command using RESP."""
    encoded_parts = [str(part).encode("utf-8") for part in parts]
    payload = f"*{len(encoded_parts)}\r\n".encode("ascii")
    for part in encoded_parts:
        payload += f"${len(part)}\r\n".encode("ascii") + part + b"\r\n"
    return payload


def read_response(sock: socket.socket) -> bytes:
    data = sock.recv(4096)
    if not data:
        raise RuntimeError("Redis returned empty response")
    if data.startswith(b"-"):
        raise RuntimeError(data.decode("utf-8", errors="replace"))
    return data


def redis_command(sock: socket.socket, *parts: str) -> bytes:
    sock.sendall(encode_command(*parts))
    return read_response(sock)


def parse_json_lines(path: Path, run_id: str) -> list[dict[str, Any]]:
    """Read P11 risk events for the current run."""
    events: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            text = line.strip()
            if not text or not text.startswith("{"):
                continue
            try:
                payload = json.loads(text)
            except json.JSONDecodeError:
                continue
            if payload.get("run_id") == run_id:
                events.append(payload)
    return events


def validate_event(event: dict[str, Any]) -> list[str]:
    """Validate the P11 risk output contract before Redis writes."""
    errors: list[str] = []
    for field, expected_type in REQUIRED_FIELDS.items():
        if field not in event:
            errors.append(f"missing:{field}")
            continue
        if not isinstance(event[field], expected_type):
            errors.append(f"type:{field}")
    if event.get("contract_version") != CONTRACT_VERSION:
        errors.append("contract_version")
    risk_score = event.get("risk_score")
    if isinstance(risk_score, int) and not (0 <= risk_score <= 100):
        errors.append("risk_score_range")
    if event.get("risk_level") not in {"LOW", "MEDIUM", "HIGH", "CRITICAL"}:
        errors.append("risk_level")
    return errors


def main() -> int:
    """Validate P11 risk events and write valid latest-state values to Redis."""
    parser = argparse.ArgumentParser(description="Validate P11 risk events and write Redis latest-state keys.")
    parser.add_argument("--input", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--sample-output", required=True)
    parser.add_argument("--invalid-output", required=True)
    parser.add_argument("--redis-host", default="127.0.0.1")
    parser.add_argument("--redis-port", type=int, default=6379)
    parser.add_argument("--key-prefix", default="finance_bigdata:p11:risk:latest")
    parser.add_argument("--sample-limit", type=int, default=50)
    args = parser.parse_args()

    input_path = Path(args.input)
    summary_path = Path(args.summary)
    sample_path = Path(args.sample_output)
    invalid_path = Path(args.invalid_output)
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    sample_path.parent.mkdir(parents=True, exist_ok=True)
    invalid_path.parent.mkdir(parents=True, exist_ok=True)

    raw_events = parse_json_lines(input_path, args.run_id)
    valid_events: list[dict[str, Any]] = []
    invalid_events: list[dict[str, Any]] = []
    level_counts: dict[str, int] = {}
    rule_counts: dict[str, int] = {}
    unique_accounts = set()

    for event in raw_events:
        errors = validate_event(event)
        if errors:
            invalid = dict(event)
            invalid["_validation_errors"] = errors
            invalid_events.append(invalid)
            continue
        valid_events.append(event)
        level = str(event["risk_level"])
        level_counts[level] = level_counts.get(level, 0) + 1
        for rule in str(event["rule_hits"]).split(";"):
            rule = rule.strip()
            if rule:
                rule_counts[rule] = rule_counts.get(rule, 0) + 1

    with socket.create_connection((args.redis_host, args.redis_port), timeout=10) as sock:
        redis_command(sock, "PING")
        for event in valid_events:
            account = str(event["event_account"])
            unique_accounts.add(account)
            key = f"{args.key_prefix}:{account}"
            value = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
            redis_command(sock, "SET", key, value)

    with sample_path.open("w", encoding="utf-8", newline="\n") as fh:
        for event in valid_events[: args.sample_limit]:
            fh.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")

    with invalid_path.open("w", encoding="utf-8", newline="\n") as fh:
        for event in invalid_events[: args.sample_limit]:
            fh.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")

    with summary_path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write("metric\tvalue\n")
        fh.write(f"run_id\t{args.run_id}\n")
        fh.write(f"contract_version\t{CONTRACT_VERSION}\n")
        fh.write(f"raw_event_count\t{len(raw_events)}\n")
        fh.write(f"schema_valid_event_count\t{len(valid_events)}\n")
        fh.write(f"schema_invalid_event_count\t{len(invalid_events)}\n")
        fh.write(f"redis_keys_written\t{len(unique_accounts)}\n")
        fh.write(f"sample_output\t{sample_path}\n")
        fh.write(f"invalid_output\t{invalid_path}\n")
        for key, value in sorted(level_counts.items()):
            fh.write(f"risk_level.{key}\t{value}\n")
        for key, value in sorted(rule_counts.items()):
            fh.write(f"rule_hit.{key}\t{value}\n")

    print(f"P11_RAW_EVENTS={len(raw_events)}")
    print(f"P11_SCHEMA_VALID_EVENTS={len(valid_events)}")
    print(f"P11_SCHEMA_INVALID_EVENTS={len(invalid_events)}")
    print(f"P11_REDIS_KEYS_WRITTEN={len(unique_accounts)}")
    return 0 if raw_events and valid_events and not invalid_events and unique_accounts else 2


if __name__ == "__main__":
    raise SystemExit(main())
