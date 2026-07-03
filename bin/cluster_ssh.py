# -*- coding: utf-8 -*-
"""Async SSH/SFTP helper for finance_bigdata cluster orchestration."""
from __future__ import annotations

import argparse
import asyncio
import os
import posixpath
import sys
from pathlib import Path

import asyncssh


def read_env_file(path: Path) -> dict[str, str]:
    """Read KEY=VALUE pairs without printing sensitive values."""
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value
    return values


def resolve_local_path(value: str) -> Path:
    """Resolve a path relative to the finance_work workspace root."""
    path = Path(value)
    if path.is_absolute():
        return path
    return Path(__file__).resolve().parent.parent / path


def require_password(args: argparse.Namespace) -> str:
    """Read the cluster password from the private password file."""
    password_file = resolve_local_path(args.password_file)
    values = read_env_file(password_file)
    password = values.get(args.password_key, "")
    if not password and args.password_key != "CLUSTER_HADOOP_COMMON_PASSWORD":
        password = values.get("CLUSTER_HADOOP_COMMON_PASSWORD", "")
    if not password:
        password = os.environ.get("FINANCE_VM_PASSWORD", "")
    if not password:
        raise SystemExit(
            f"Cluster password key {args.password_key} was not found in {password_file}"
        )
    return password


def connect_timeouts(args: argparse.Namespace) -> dict[str, int]:
    """Return bounded SSH connection timeout settings."""
    return {
        "connect_timeout": args.connect_timeout,
        "login_timeout": args.login_timeout,
    }


def auth_options() -> dict[str, object]:
    """Use password-only auth to avoid slow GSSAPI/key probing on this lab VM."""
    return {
        "client_keys": [],
        "agent_path": None,
        "agent_identities": None,
        "host_based_auth": False,
        "public_key_auth": False,
        "kbdint_auth": False,
        "password_auth": True,
        "preferred_auth": ["password"],
        "gss_kex": False,
        "gss_auth": False,
    }


async def run_command(args: argparse.Namespace) -> int:
    """Run a command or local script content on the target cluster host."""
    password = require_password(args)
    command = args.command
    if args.script:
        command = Path(args.script).read_text(encoding="utf-8")
    if not command:
        raise SystemExit("No command or script provided")

    async with asyncssh.connect(
        args.host,
        username=args.user,
        password=password,
        known_hosts=None,
        **auth_options(),
        **connect_timeouts(args),
    ) as conn:
        stdin_chunks = []
        if args.sudo_stdin:
            stdin_chunks.append(password + "\n")
        if args.stdin_file:
            stdin_chunks.append(Path(args.stdin_file).read_text(encoding="utf-8"))
        stdin_data = "".join(stdin_chunks) if stdin_chunks else None
        result = await conn.run(
            command,
            input=stdin_data,
            check=False,
            term_type=None,
            timeout=args.command_timeout,
        )
        if result.stdout:
            sys.stdout.write(result.stdout)
        if result.stderr:
            sys.stderr.write(result.stderr)
        return result.exit_status


async def upload_files(args: argparse.Namespace) -> int:
    """Upload local files to the remote project directory."""
    password = require_password(args)
    remote_dir = args.remote_dir.rstrip("/")
    async with asyncssh.connect(
        args.host,
        username=args.user,
        password=password,
        known_hosts=None,
        **auth_options(),
        **connect_timeouts(args),
    ) as conn:
        await conn.run(
            f"mkdir -p {quote_remote(remote_dir)}",
            check=True,
            timeout=args.command_timeout,
        )
        async with conn.start_sftp_client() as sftp:
            for local in args.local:
                local_path = Path(local)
                remote_path = posixpath.join(remote_dir, local_path.name)
                await sftp.put(str(local_path), remote_path)
                print(f"UPLOAD\t{local_path}\t{remote_path}")
    return 0


async def download_files(args: argparse.Namespace) -> int:
    """Download remote evidence files into a local run directory."""
    password = require_password(args)
    local_dir = Path(args.local_dir)
    local_dir.mkdir(parents=True, exist_ok=True)
    async with asyncssh.connect(
        args.host,
        username=args.user,
        password=password,
        known_hosts=None,
        **auth_options(),
        **connect_timeouts(args),
    ) as conn:
        async with conn.start_sftp_client() as sftp:
            for remote in args.remote:
                remote_name = posixpath.basename(remote.rstrip("/"))
                local_path = local_dir / remote_name
                await sftp.get(remote, str(local_path))
                print(f"DOWNLOAD\t{remote}\t{local_path}")
    return 0


def quote_remote(value: str) -> str:
    """Quote one path/argument for a POSIX shell command."""
    return "'" + value.replace("'", "'\"'\"'") + "'"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Finance project SSH/SFTP helper.")
    parser.add_argument("--host", default="CLUSTER_NODE1_IP")
    parser.add_argument("--user", default="common")
    parser.add_argument("--connect-timeout", type=int, default=20)
    parser.add_argument("--login-timeout", type=int, default=20)
    parser.add_argument("--password-file", default="PRIVATE_CREDENTIALS_ENV")
    parser.add_argument("--password-key", default="CLUSTER_HADOOP_COMMON_PASSWORD")
    parser.add_argument("--command-timeout", type=int, default=60)
    subparsers = parser.add_subparsers(dest="action", required=True)

    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--command", default="")
    run_parser.add_argument("--script", default="")
    run_parser.add_argument("--sudo-stdin", action="store_true")
    run_parser.add_argument("--stdin-file", default="")

    upload_parser = subparsers.add_parser("upload")
    upload_parser.add_argument("--remote-dir", required=True)
    upload_parser.add_argument("local", nargs="+")

    download_parser = subparsers.add_parser("download")
    download_parser.add_argument("--local-dir", required=True)
    download_parser.add_argument("remote", nargs="+")
    return parser


async def async_main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.action == "run":
        return await run_command(args)
    if args.action == "upload":
        return await upload_files(args)
    if args.action == "download":
        return await download_files(args)
    raise SystemExit(f"Unsupported action: {args.action}")


def main() -> int:
    return asyncio.run(async_main())


if __name__ == "__main__":
    raise SystemExit(main())

