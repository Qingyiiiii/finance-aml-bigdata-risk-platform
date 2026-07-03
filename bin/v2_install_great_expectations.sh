set -euo pipefail

GX_VENV="/export/server/venv/great_expectations"
GX_PROJECT="/home/common/tmp/finance_bigdata_project/v2_quality/great_expectations"
GX_RESULTS="${GX_PROJECT}/results"
GX_SMOKE="${GX_PROJECT}/gx_finance_v2_smoke.py"

echo "[great-expectations] host=$(hostname) user=$(whoami)"

if ! command -v python3.11 >/dev/null 2>&1; then
  echo "[python] installing python3.11"
  sudo dnf -y install python3.11 python3.11-pip python3.11-devel
else
  echo "[python] found $(python3.11 --version)"
fi

echo "[directories] preparing GX venv and project directories"
sudo mkdir -p /export/server/venv "${GX_PROJECT}" "${GX_RESULTS}" /export/logs/great_expectations
sudo chown -R common:common /export/server/venv "${GX_PROJECT}" /export/logs/great_expectations

if [ ! -f "${GX_VENV}/pyvenv.cfg" ]; then
  echo "[venv] creating ${GX_VENV}"
  python3.11 -m venv "${GX_VENV}"
else
  echo "[venv] exists ${GX_VENV}"
fi

echo "[pip] upgrading build tooling"
"${GX_VENV}/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
"${GX_VENV}/bin/python" -m pip install -U pip wheel setuptools

echo "[pip] installing GX Core with Trino and file-data dependencies"
"${GX_VENV}/bin/python" -m pip install -U \
  'great_expectations[trino]' \
  pandas \
  pyarrow \
  pyyaml

echo "[smoke] writing finance GX smoke validation"
cat > "${GX_SMOKE}" <<'PY'
from __future__ import annotations

import json
from pathlib import Path

import great_expectations as gx
import pandas as pd


PROJECT_DIR = Path("/home/common/tmp/finance_bigdata_project/v2_quality/great_expectations")
RESULTS_DIR = PROJECT_DIR / "results"
RESULTS_DIR.mkdir(parents=True, exist_ok=True)


def result_to_payload(result):
    if hasattr(result, "to_json_dict"):
        return result.to_json_dict()
    if hasattr(result, "model_dump"):
        return result.model_dump(mode="json")
    return {"repr": str(result), "success": bool(getattr(result, "success", False))}


def main() -> int:
    df = pd.DataFrame(
        [
            {
                "transaction_id": "tx-0001",
                "account_number": "acct-001",
                "amount_paid": 128.50,
                "payment_currency": "CNY",
                "risk_score": 0.12,
            },
            {
                "transaction_id": "tx-0002",
                "account_number": "acct-002",
                "amount_paid": 9900.00,
                "payment_currency": "USD",
                "risk_score": 0.87,
            },
            {
                "transaction_id": "tx-0003",
                "account_number": "acct-001",
                "amount_paid": 256.00,
                "payment_currency": "CNY",
                "risk_score": 0.41,
            },
        ]
    )

    context = gx.get_context()
    data_source = context.data_sources.add_pandas("finance_v2_pandas")
    data_asset = data_source.add_dataframe_asset(name="finance_transaction_sample")
    batch_definition = data_asset.add_batch_definition_whole_dataframe("whole_dataframe")
    batch = batch_definition.get_batch(batch_parameters={"dataframe": df})

    expectations = [
        gx.expectations.ExpectTableRowCountToBeBetween(min_value=1, max_value=1000),
        gx.expectations.ExpectColumnValuesToNotBeNull(column="transaction_id"),
        gx.expectations.ExpectColumnValuesToNotBeNull(column="account_number"),
        gx.expectations.ExpectColumnValuesToBeBetween(column="amount_paid", min_value=0),
        gx.expectations.ExpectColumnValuesToBeBetween(
            column="risk_score", min_value=0, max_value=1
        ),
        gx.expectations.ExpectColumnValuesToBeInSet(
            column="payment_currency", value_set=["CNY", "USD", "EUR", "HKD"]
        ),
    ]

    validation_results = []
    for expectation in expectations:
        result = batch.validate(expectation)
        payload = result_to_payload(result)
        validation_results.append(
            {
                "expectation": expectation.__class__.__name__,
                "success": bool(payload.get("success", getattr(result, "success", False))),
                "result": payload.get("result", {}),
            }
        )

    summary = {
        "component": "Great Expectations",
        "gx_version": gx.__version__,
        "context_type": type(context).__name__,
        "sample_rows": int(len(df)),
        "evaluated_expectations": len(validation_results),
        "successful_expectations": sum(1 for item in validation_results if item["success"]),
        "all_success": all(item["success"] for item in validation_results),
        "validation_results": validation_results,
    }

    output_path = RESULTS_DIR / "finance_gx_smoke_result.json"
    output_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if summary["all_success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
PY

chmod 700 "${GX_SMOKE}"

echo "[validation] GX import and version"
"${GX_VENV}/bin/python" - <<'PY'
import great_expectations as gx
print(gx.__version__)
PY

echo "[validation] running finance GX smoke validation"
"${GX_VENV}/bin/python" "${GX_SMOKE}" | tee /export/logs/great_expectations/finance_gx_smoke.log

echo "[validation] installed packages"
"${GX_VENV}/bin/python" -m pip show great_expectations pandas pyarrow trino | sed -n '1,120p'

echo "[great-expectations] done"
