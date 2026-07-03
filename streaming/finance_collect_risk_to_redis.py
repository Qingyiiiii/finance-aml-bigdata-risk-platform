# -*- coding: utf-8 -*-
"""Write P6 risk-rule events into Redis latest-state keys."""
from __future__ import annotations

import argparse
import json
import socket
from pathlib import Path
from typing import Any


def encode_command(*parts: str) -> bytes:
    """Encode a Redis command using the RESP wire format."""
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
    """Read P6 risk events and keep only the current run_id."""
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


def main() -> int:
    """Write current-run P6 risk events into Redis latest-state keys."""
    parser = argparse.ArgumentParser(description="Write P6 risk events into Redis latest-state keys.")
    parser.add_argument("--input", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--sample-output", required=True)
    parser.add_argument("--redis-host", default="127.0.0.1")
    parser.add_argument("--redis-port", type=int, default=6379)
    parser.add_argument("--key-prefix", default="finance_bigdata:risk:latest")
    parser.add_argument("--sample-limit", type=int, default=50)
    args = parser.parse_args()

    input_path = Path(args.input)
    summary_path = Path(args.summary)
    sample_path = Path(args.sample_output)
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    sample_path.parent.mkdir(parents=True, exist_ok=True)

    events = parse_json_lines(input_path, args.run_id)
    unique_accounts = set()
    risk_type_counts: dict[str, int] = {}

    with socket.create_connection((args.redis_host, args.redis_port), timeout=10) as sock:
        redis_command(sock, "PING")
        for event in events:
            account = str(event.get("event_account", ""))
            if not account:
                continue
            unique_accounts.add(account)
            risk_type = str(event.get("risk_type", "UNKNOWN"))
            risk_type_counts[risk_type] = risk_type_counts.get(risk_type, 0) + 1
            key = f"{args.key_prefix}:{account}"
            value = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
            redis_command(sock, "SET", key, value)

    with sample_path.open("w", encoding="utf-8", newline="\n") as fh:
        for event in events[: args.sample_limit]:
            fh.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")

    with summary_path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write("metric\tvalue\n")
        fh.write(f"run_id\t{args.run_id}\n")
        fh.write(f"risk_event_count\t{len(events)}\n")
        fh.write(f"redis_keys_written\t{len(unique_accounts)}\n")
        fh.write(f"sample_output\t{sample_path}\n")
        for key, value in sorted(risk_type_counts.items()):
            fh.write(f"risk_type.{key}\t{value}\n")

    print(f"RISK_EVENT_COUNT={len(events)}")
    print(f"REDIS_KEYS_WRITTEN={len(unique_accounts)}")
    return 0 if events and unique_accounts else 2


if __name__ == "__main__":
    raise SystemExit(main())
