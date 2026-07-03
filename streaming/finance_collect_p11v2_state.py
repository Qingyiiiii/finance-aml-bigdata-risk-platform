# -*- coding: utf-8 -*-
"""Validate P11v2 risk events and write Redis cache plus HBase durable state."""
from __future__ import annotations

import argparse
import json
import re
import socket
import subprocess
import time
import zlib
from pathlib import Path
from typing import Any


CONTRACT_VERSION = "p11v2_realtime_state_contract_v1"
STATE_STORE_VERSION = "hbase_account_risk_state_v1"
HBASE_TABLE = "finance_bigdata_v2:account_risk_state"
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
    "state_operation": str,
    "state_store_version": str,
    "scored_at": str,
}


def encode_command(*parts: str) -> bytes:
    encoded_parts = [str(part).encode("utf-8") for part in parts]
    payload = f"*{len(encoded_parts)}\r\n".encode("ascii")
    for part in encoded_parts:
        payload += f"${len(part)}\r\n".encode("ascii") + part + b"\r\n"
    return payload


def read_response(sock: socket.socket) -> bytes:
    data = sock.recv(1024 * 1024)
    if not data:
        raise RuntimeError("Redis returned empty response")
    if data.startswith(b"-"):
        raise RuntimeError(data.decode("utf-8", errors="replace"))
    return data


def redis_command(sock: socket.socket, *parts: str) -> bytes:
    sock.sendall(encode_command(*parts))
    return read_response(sock)


def redis_get(sock: socket.socket, key: str) -> str:
    response = redis_command(sock, "GET", key)
    if response.startswith(b"$-1"):
        return ""
    match = re.match(rb"\$(\d+)\r\n", response)
    if not match:
        return ""
    size = int(match.group(1))
    start = len(match.group(0))
    return response[start : start + size].decode("utf-8", errors="replace")


def parse_json_lines(path: Path, run_id: str) -> list[dict[str, Any]]:
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
    errors: list[str] = []
    for field, expected_type in REQUIRED_FIELDS.items():
        if field not in event:
            errors.append(f"missing:{field}")
            continue
        if not isinstance(event[field], expected_type):
            errors.append(f"type:{field}")
    if event.get("contract_version") != CONTRACT_VERSION:
        errors.append("contract_version")
    if event.get("state_operation") != "UPSERT":
        errors.append("state_operation")
    if event.get("state_store_version") != STATE_STORE_VERSION:
        errors.append("state_store_version")
    risk_score = event.get("risk_score")
    if isinstance(risk_score, int) and not (0 <= risk_score <= 100):
        errors.append("risk_score_range")
    if event.get("risk_level") not in {"LOW", "MEDIUM", "HIGH", "CRITICAL"}:
        errors.append("risk_level")
    return errors


def hbase_row_key(account: str) -> str:
    salt = zlib.crc32(account.encode("utf-8")) & 0xFFFFFFFF
    return f"{salt:08x}#{account}"


def hbase_quote(value: Any) -> str:
    text = "" if value is None else str(value)
    return "'" + text.replace("\\", "\\\\").replace("'", "\\'") + "'"


def build_hbase_put_script(events_by_account: dict[str, dict[str, Any]], path: Path) -> None:
    lines = [
        "begin",
        "  create_namespace 'finance_bigdata_v2'",
        "rescue Exception => e",
        "  puts \"namespace_check=#{e.message}\"",
        "end",
        "begin",
        "  create 'finance_bigdata_v2:account_risk_state', 's', 'm', 'r', 'meta'",
        "rescue Exception => e",
        "  puts \"table_check=#{e.message}\"",
        "end",
    ]
    for account, event in events_by_account.items():
        row = hbase_row_key(account)
        updated_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        cells = {
            "s:risk_score": event["risk_score"],
            "s:risk_level": event["risk_level"],
            "s:state_operation": event["state_operation"],
            "s:updated_at": updated_at,
            "m:amount_paid": event["amount_paid"],
            "m:payment_currency": event["payment_currency"],
            "m:payment_format": event["payment_format"],
            "r:risk_reasons": event["risk_reasons"],
            "r:rule_hits": event["rule_hits"],
            "meta:run_id": event["run_id"],
            "meta:transaction_id": event["transaction_id"],
            "meta:event_time": event["event_time"],
            "meta:contract_version": event["contract_version"],
            "meta:counterparty_account": event["counterparty_account"],
            "meta:feature_snapshot_version": event["feature_snapshot_version"],
        }
        for column, value in cells.items():
            lines.append(f"put {hbase_quote(HBASE_TABLE)}, {hbase_quote(row)}, {hbase_quote(column)}, {hbase_quote(value)}")
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")


def build_hbase_readback_script(sample_events: list[dict[str, Any]], path: Path) -> None:
    lines: list[str] = []
    for event in sample_events:
        account = str(event["event_account"])
        row = hbase_row_key(account)
        lines.append(f"puts \"P11V2_READBACK\\t{account}\\t{row}\"")
        lines.append(
            "get "
            f"{hbase_quote(HBASE_TABLE)}, {hbase_quote(row)}, "
            "{COLUMN => ['s:risk_score','s:risk_level','meta:run_id','meta:transaction_id']}"
        )
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")


def run_hbase_shell(hbase_bin: str, script: Path, stdout_path: Path, stderr_path: Path) -> int:
    with script.open("rb") as stdin, stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        result = subprocess.run([hbase_bin, "shell", "-n"], stdin=stdin, stdout=stdout, stderr=stderr, check=False)
    return int(result.returncode)


def parse_hbase_readback(output_path: Path) -> dict[str, dict[str, str]]:
    records: dict[str, dict[str, str]] = {}
    current_account = ""
    current_row = ""
    for line in output_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("P11V2_READBACK\t"):
            _, current_account, current_row = line.split("\t", 2)
            records[current_account] = {"row_key": current_row}
            continue
        if not current_account or "value=" not in line:
            continue
        value = line.split("value=", 1)[1].strip().split()[0]
        if "s:risk_score" in line:
            records[current_account]["hbase_risk_score"] = value
        elif "s:risk_level" in line:
            records[current_account]["hbase_risk_level"] = value
        elif "meta:run_id" in line:
            records[current_account]["hbase_run_id"] = value
        elif "meta:transaction_id" in line:
            records[current_account]["hbase_transaction_id"] = value
    return records


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate P11v2 risk events and land state to Redis/HBase.")
    parser.add_argument("--input", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--sample-output", required=True)
    parser.add_argument("--invalid-output", required=True)
    parser.add_argument("--hbase-readback-output", required=True)
    parser.add_argument("--hbase-put-script", required=True)
    parser.add_argument("--hbase-put-out", required=True)
    parser.add_argument("--hbase-put-err", required=True)
    parser.add_argument("--hbase-readback-script", required=True)
    parser.add_argument("--hbase-readback-raw", required=True)
    parser.add_argument("--hbase-readback-err", required=True)
    parser.add_argument("--redis-host", default="127.0.0.1")
    parser.add_argument("--redis-port", type=int, default=6379)
    parser.add_argument("--redis-key-prefix", default="finance_bigdata:v2:risk:latest")
    parser.add_argument("--hbase-bin", default="/export/server/hbase/bin/hbase")
    parser.add_argument("--sample-limit", type=int, default=50)
    args = parser.parse_args()

    input_path = Path(args.input)
    summary_path = Path(args.summary)
    sample_path = Path(args.sample_output)
    invalid_path = Path(args.invalid_output)
    hbase_readback_path = Path(args.hbase_readback_output)
    hbase_put_script = Path(args.hbase_put_script)
    hbase_put_out = Path(args.hbase_put_out)
    hbase_put_err = Path(args.hbase_put_err)
    hbase_readback_script = Path(args.hbase_readback_script)
    hbase_readback_raw = Path(args.hbase_readback_raw)
    hbase_readback_err = Path(args.hbase_readback_err)

    for path in [
        summary_path,
        sample_path,
        invalid_path,
        hbase_readback_path,
        hbase_put_script,
        hbase_put_out,
        hbase_put_err,
        hbase_readback_script,
        hbase_readback_raw,
        hbase_readback_err,
    ]:
        path.parent.mkdir(parents=True, exist_ok=True)

    raw_events = parse_json_lines(input_path, args.run_id)
    valid_events: list[dict[str, Any]] = []
    invalid_events: list[dict[str, Any]] = []
    level_counts: dict[str, int] = {}
    rule_counts: dict[str, int] = {}
    latest_by_account: dict[str, dict[str, Any]] = {}

    for event in raw_events:
        errors = validate_event(event)
        if errors:
            invalid = dict(event)
            invalid["_validation_errors"] = errors
            invalid_events.append(invalid)
            continue
        valid_events.append(event)
        account = str(event["event_account"])
        latest_by_account[account] = event
        level = str(event["risk_level"])
        level_counts[level] = level_counts.get(level, 0) + 1
        for rule in str(event["rule_hits"]).split(";"):
            rule = rule.strip()
            if rule:
                rule_counts[rule] = rule_counts.get(rule, 0) + 1

    redis_readbacks: dict[str, dict[str, Any]] = {}
    with socket.create_connection((args.redis_host, args.redis_port), timeout=10) as sock:
        redis_command(sock, "PING")
        for account, event in latest_by_account.items():
            key = f"{args.redis_key_prefix}:{account}"
            value = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
            redis_command(sock, "SET", key, value)
        for account, event in list(latest_by_account.items())[: args.sample_limit]:
            key = f"{args.redis_key_prefix}:{account}"
            payload = redis_get(sock, key)
            redis_readbacks[account] = json.loads(payload) if payload else {}

    build_hbase_put_script(latest_by_account, hbase_put_script)
    hbase_put_rc = run_hbase_shell(args.hbase_bin, hbase_put_script, hbase_put_out, hbase_put_err)

    sample_events = list(latest_by_account.values())[: args.sample_limit]
    build_hbase_readback_script(sample_events, hbase_readback_script)
    hbase_readback_rc = run_hbase_shell(args.hbase_bin, hbase_readback_script, hbase_readback_raw, hbase_readback_err)
    hbase_readbacks = parse_hbase_readback(hbase_readback_raw)

    consistency_rows: list[tuple[str, str, str, str, str, str, str]] = []
    consistency_fail_count = 0
    for event in sample_events:
        account = str(event["event_account"])
        redis_event = redis_readbacks.get(account, {})
        hbase_event = hbase_readbacks.get(account, {})
        redis_score = str(redis_event.get("risk_score", ""))
        redis_level = str(redis_event.get("risk_level", ""))
        hbase_score = str(hbase_event.get("hbase_risk_score", ""))
        hbase_level = str(hbase_event.get("hbase_risk_level", ""))
        status = "PASS" if redis_score == hbase_score and redis_level == hbase_level and hbase_score else "FAIL"
        if status != "PASS":
            consistency_fail_count += 1
        consistency_rows.append((account, hbase_row_key(account), redis_score, redis_level, hbase_score, hbase_level, status))

    with sample_path.open("w", encoding="utf-8", newline="\n") as fh:
        for event in valid_events[: args.sample_limit]:
            fh.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")

    with invalid_path.open("w", encoding="utf-8", newline="\n") as fh:
        for event in invalid_events[: args.sample_limit]:
            fh.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")

    with hbase_readback_path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write("event_account\thbase_row_key\tredis_risk_score\tredis_risk_level\thbase_risk_score\thbase_risk_level\tstatus\n")
        for row in consistency_rows:
            fh.write("\t".join(row) + "\n")

    with summary_path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write("metric\tvalue\n")
        fh.write(f"run_id\t{args.run_id}\n")
        fh.write(f"contract_version\t{CONTRACT_VERSION}\n")
        fh.write(f"state_store_version\t{STATE_STORE_VERSION}\n")
        fh.write(f"raw_event_count\t{len(raw_events)}\n")
        fh.write(f"schema_valid_event_count\t{len(valid_events)}\n")
        fh.write(f"schema_invalid_event_count\t{len(invalid_events)}\n")
        fh.write(f"redis_keys_written\t{len(latest_by_account)}\n")
        fh.write(f"hbase_rows_written\t{len(latest_by_account)}\n")
        fh.write(f"hbase_put_exit_code\t{hbase_put_rc}\n")
        fh.write(f"hbase_readback_exit_code\t{hbase_readback_rc}\n")
        fh.write(f"hbase_readback_sample_count\t{len(consistency_rows)}\n")
        fh.write(f"redis_hbase_consistency_fail_count\t{consistency_fail_count}\n")
        fh.write(f"redis_key_prefix\t{args.redis_key_prefix}\n")
        fh.write(f"hbase_table\t{HBASE_TABLE}\n")
        fh.write(f"sample_output\t{sample_path}\n")
        fh.write(f"invalid_output\t{invalid_path}\n")
        fh.write(f"hbase_readback_output\t{hbase_readback_path}\n")
        for key, value in sorted(level_counts.items()):
            fh.write(f"risk_level.{key}\t{value}\n")
        for key, value in sorted(rule_counts.items()):
            fh.write(f"rule_hit.{key}\t{value}\n")

    print(f"P11V2_RAW_EVENTS={len(raw_events)}")
    print(f"P11V2_SCHEMA_VALID_EVENTS={len(valid_events)}")
    print(f"P11V2_SCHEMA_INVALID_EVENTS={len(invalid_events)}")
    print(f"P11V2_REDIS_KEYS_WRITTEN={len(latest_by_account)}")
    print(f"P11V2_HBASE_ROWS_WRITTEN={len(latest_by_account)}")
    print(f"P11V2_REDIS_HBASE_CONSISTENCY_FAILS={consistency_fail_count}")

    ok = (
        bool(raw_events)
        and bool(valid_events)
        and not invalid_events
        and bool(latest_by_account)
        and hbase_put_rc == 0
        and hbase_readback_rc == 0
        and consistency_rows
        and consistency_fail_count == 0
    )
    return 0 if ok else 2


if __name__ == "__main__":
    raise SystemExit(main())
