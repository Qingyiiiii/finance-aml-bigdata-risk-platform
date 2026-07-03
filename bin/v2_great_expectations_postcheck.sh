set -euo pipefail

GX_VENV="/export/server/venv/great_expectations"
GX_PROJECT="/home/common/tmp/finance_bigdata_project/v2_quality/great_expectations"
GX_RESULT="${GX_PROJECT}/results/finance_gx_smoke_result.json"

echo "[great-expectations-postcheck] python"
"${GX_VENV}/bin/python" --version

echo "[great-expectations-postcheck] version"
"${GX_VENV}/bin/python" - <<'PY'
import great_expectations as gx
import pandas as pd
import pyarrow as pa
import trino
print("great_expectations=" + gx.__version__)
print("pandas=" + pd.__version__)
print("pyarrow=" + pa.__version__)
print("trino=" + trino.__version__)
PY

echo "[great-expectations-postcheck] smoke result"
"${GX_VENV}/bin/python" - <<'PY'
import json
from pathlib import Path

result_path = Path("/home/common/tmp/finance_bigdata_project/v2_quality/great_expectations/results/finance_gx_smoke_result.json")
payload = json.loads(result_path.read_text(encoding="utf-8"))
print("result_path=" + str(result_path))
print("all_success=" + str(payload["all_success"]))
print("evaluated_expectations=" + str(payload["evaluated_expectations"]))
print("successful_expectations=" + str(payload["successful_expectations"]))
if not payload["all_success"]:
    raise SystemExit(1)
PY

echo "[great-expectations-postcheck] project files"
find "${GX_PROJECT}" -maxdepth 3 -type f | sort
