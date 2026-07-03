from __future__ import annotations

import argparse
import json
from pathlib import Path

import great_expectations as gx
import pandas as pd


def result_to_payload(result):
    if hasattr(result, "to_json_dict"):
        return result.to_json_dict()
    if hasattr(result, "model_dump"):
        return result.model_dump(mode="json")
    return {"success": bool(getattr(result, "success", False)), "repr": str(result)}


def payload_success(payload: dict) -> bool:
    return bool(payload.get("success", False))


def payload_result(payload: dict) -> dict:
    result = payload.get("result", {})
    return result if isinstance(result, dict) else {"result": str(result)}


def write_summary_tsv(path: Path, rows: list[dict[str, str]]) -> None:
    columns = ["expectation", "status", "observed_value", "detail"]
    lines = ["\t".join(columns)]
    for row in rows:
        cells = []
        for column in columns:
            value = str(row.get(column, ""))
            value = value.replace("\t", " ").replace("\r", " ").replace("\n", " ")
            cells.append(value)
        lines.append("\t".join(cells))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run P17v2 GX checks on a TSV evidence table.")
    parser.add_argument("--input", required=True)
    parser.add_argument("--output-json", required=True)
    parser.add_argument("--summary-tsv", required=True)
    parser.add_argument("--run-name", required=True)
    parser.add_argument("--min-row-count", type=int, default=25)
    parser.add_argument(
        "--smoke-result",
        default="/home/common/tmp/finance_bigdata_project/v2_quality/great_expectations/results/finance_gx_smoke_result.json",
    )
    args = parser.parse_args()

    input_path = Path(args.input)
    output_json = Path(args.output_json)
    summary_tsv = Path(args.summary_tsv)
    smoke_path = Path(args.smoke_result)

    df = pd.read_csv(input_path, sep="\t", dtype=str).fillna("")
    context = gx.get_context()
    datasource = context.data_sources.add_pandas(f"finance_v2_p17_{args.run_name}")
    asset = datasource.add_dataframe_asset(name="p17v2_quality_results")
    batch_definition = asset.add_batch_definition_whole_dataframe("whole_dataframe")
    batch = batch_definition.get_batch(batch_parameters={"dataframe": df})

    required_columns = [
        "rule_group",
        "rule_name",
        "expected",
        "actual",
        "status",
        "source_evidence",
        "detail",
        "check_type",
    ]

    expectations = [
        gx.expectations.ExpectTableRowCountToBeBetween(
            min_value=args.min_row_count,
            max_value=1000,
        ),
        gx.expectations.ExpectTableColumnsToMatchSet(
            column_set=required_columns,
            exact_match=False,
        ),
        gx.expectations.ExpectColumnValuesToNotBeNull(column="rule_group"),
        gx.expectations.ExpectColumnValuesToNotBeNull(column="rule_name"),
        gx.expectations.ExpectColumnValuesToNotBeNull(column="status"),
        gx.expectations.ExpectColumnValuesToBeInSet(column="status", value_set=["PASS"]),
        gx.expectations.ExpectColumnValuesToNotBeNull(column="source_evidence"),
        gx.expectations.ExpectColumnValuesToBeInSet(
            column="check_type",
            value_set=["gx_framework", "source_evidence", "custom_gate"],
        ),
    ]

    validation_results: list[dict] = []
    summary_rows: list[dict[str, str]] = []
    for expectation in expectations:
        result = batch.validate(expectation)
        payload = result_to_payload(result)
        success = payload_success(payload)
        result_payload = payload_result(payload)
        observed = result_payload.get("observed_value", "")
        if observed == "":
            observed = result_payload.get("element_count", "")
        validation_results.append(
            {
                "expectation": expectation.__class__.__name__,
                "success": success,
                "result": result_payload,
            }
        )
        summary_rows.append(
            {
                "expectation": expectation.__class__.__name__,
                "status": "PASS" if success else "FAIL",
                "observed_value": str(observed),
                "detail": json.dumps(result_payload, ensure_ascii=False, sort_keys=True),
            }
        )

    smoke_payload: dict = {}
    smoke_success = False
    if smoke_path.exists():
        smoke_payload = json.loads(smoke_path.read_text(encoding="utf-8"))
        smoke_success = bool(smoke_payload.get("all_success", False))

    summary = {
        "component": "Great Expectations",
        "run_name": args.run_name,
        "gx_version": gx.__version__,
        "context_type": type(context).__name__,
        "input_path": str(input_path),
        "input_rows": int(len(df)),
        "smoke_result_path": str(smoke_path),
        "smoke_exists": smoke_path.exists(),
        "smoke_all_success": smoke_success,
        "smoke_evaluated_expectations": smoke_payload.get("evaluated_expectations"),
        "smoke_successful_expectations": smoke_payload.get("successful_expectations"),
        "evaluated_expectations": len(validation_results),
        "successful_expectations": sum(1 for item in validation_results if item["success"]),
        "all_success": smoke_success and all(item["success"] for item in validation_results),
        "validation_results": validation_results,
    }

    output_json.parent.mkdir(parents=True, exist_ok=True)
    output_json.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    write_summary_tsv(summary_tsv, summary_rows)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary["all_success"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
