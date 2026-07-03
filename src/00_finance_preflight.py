# -*- coding: utf-8 -*-
"""Run P0 raw-file preflight for the finance_bigdata project."""
from __future__ import annotations

import argparse
from pathlib import Path

from finance_utils import (
    PROJECT_ROOT,
    TRANSACTION_RAW_COLUMNS,
    configured_paths,
    file_size_mb,
    load_config,
    read_csv_header,
    timestamped_run_dir,
    write_json,
    write_text,
    write_tsv,
)


def inspect_required_file(name: str, path: Path, expected_header: list[str] | None) -> dict[str, object]:
    """Check one required raw input file and its header contract."""
    result: dict[str, object] = {
        "file_role": name,
        "path": str(path),
        "exists": path.exists(),
        "size_mb": "",
        "header_status": "not_checked",
        "detail": "",
    }
    if not path.exists():
        result["detail"] = "missing"
        return result

    result["size_mb"] = file_size_mb(path)
    if expected_header is None:
        result["header_status"] = "not_applicable"
        result["detail"] = "plain pattern file"
        return result

    header = read_csv_header(path)
    result["header"] = header
    result["header_status"] = "pass" if header == expected_header else "fail"
    result["detail"] = "header matches expected schema" if header == expected_header else "header differs"
    return result


def build_report(config: dict[str, object], run_dir: Path, checks: list[dict[str, object]]) -> str:
    """Render the human-readable P0 preflight Markdown report."""
    dataset = config["project"]["default_dataset"]  # type: ignore[index]
    lines = [
        "# P0 Finance Preflight Report",
        "",
        f"- Project root: `{PROJECT_ROOT}`",
        f"- Run dir: `{run_dir}`",
        f"- Dataset: `{dataset}`",
        f"- Scope: local raw file readability and schema checks",
        "",
        "## Required Files",
        "",
        "| Role | Exists | Size MB | Header status | Detail |",
        "| --- | --- | ---: | --- | --- |",
    ]
    for item in checks:
        lines.append(
            f"| {item['file_role']} | {item['exists']} | {item['size_mb']} | "
            f"{item['header_status']} | {item['detail']} |"
        )
    lines.extend(
        [
            "",
            "## Boundary",
            "",
            "- This preflight only reads `datas` under the finance workspace.",
            "- It does not read or write external project directories.",
            "- It does not submit Spark/Flink/Trino/Doris/Kafka jobs.",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="P0 finance raw data preflight.")
    parser.add_argument("--config", default="config/finance_bigdata.local.yaml")
    args = parser.parse_args()

    config = load_config(args.config)
    paths = configured_paths(config)
    output_dir = paths["output_dir"]
    run_dir = timestamped_run_dir(output_dir, "p0_preflight")

    required_checks = [
        inspect_required_file("transaction", paths["transaction"], TRANSACTION_RAW_COLUMNS),
        inspect_required_file(
            "account",
            paths["account"],
            ["Bank Name", "Bank ID", "Account Number", "Entity ID", "Entity Name"],
        ),
        inspect_required_file("pattern", paths["pattern"], None),
    ]

    inventory_rows = []
    for file_path in sorted(paths["raw_dir"].glob("*")):
        if file_path.is_file():
            inventory_rows.append(
                {
                    "file_name": file_path.name,
                    "size_bytes": file_path.stat().st_size,
                    "size_mb": file_size_mb(file_path),
                }
            )

    summary_rows = []
    failed = False
    for item in required_checks:
        status = "PASS"
        if not item["exists"] or item["header_status"] == "fail":
            status = "FAIL"
            failed = True
        summary_rows.append(
            {
                "check": item["file_role"],
                "status": status,
                "detail": item["detail"],
            }
        )

    write_json(run_dir / "preflight_checks.json", required_checks)
    write_tsv(
        run_dir / "file_inventory.tsv",
        inventory_rows,
        ["file_name", "size_bytes", "size_mb"],
    )
    write_tsv(run_dir / "summary.tsv", summary_rows, ["check", "status", "detail"])
    write_text(run_dir / "preflight_report.md", build_report(config, run_dir, required_checks))

    print(f"P0_RUN_DIR={run_dir}")
    print("P0_STATUS=FAIL" if failed else "P0_STATUS=PASS")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
