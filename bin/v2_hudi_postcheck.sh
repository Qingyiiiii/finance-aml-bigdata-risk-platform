set -euo pipefail

source /etc/profile.d/bigdata.sh 2>/dev/null || true
export JAVA_HOME=/export/server/jdk17
export PATH=/export/server/spark/bin:/export/server/hadoop/bin:/export/server/hadoop/sbin:$JAVA_HOME/bin:$PATH

HUDI_JAR="/export/server/spark/jars/hudi-spark3.5-bundle_2.12-1.2.0.jar"
HUDI_SMOKE_PATH="/lakehouse/projects/finance_bigdata/hudi/account_state_hudi_smoke"
HUDI_SMOKE_RESULT="/home/common/tmp/finance_bigdata_project/v2_hudi/hudi_finance_smoke_result.json"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10"

echo "[hudi-postcheck] spark"
spark-submit --version 2>&1 | sed -n '1,10p'

echo "[hudi-postcheck] result"
python3 - <<'PY'
import json
from pathlib import Path

path = Path("/home/common/tmp/finance_bigdata_project/v2_hudi/hudi_finance_smoke_result.json")
payload = json.loads(path.read_text(encoding="utf-8"))
print("result_path=" + str(path))
print("success=" + str(payload["success"]))
print("row_count_after_upsert=" + str(payload["row_count_after_upsert"]))
print("acct_002_risk_level=" + str(payload["acct_002_risk_level"]))
if not payload["success"]:
    raise SystemExit(1)
PY

echo "[hudi-postcheck] hdfs"
hdfs dfs -test -d "${HUDI_SMOKE_PATH}"
hdfs dfs -ls "${HUDI_SMOKE_PATH}" | sed -n '1,40p'

echo "[hudi-postcheck] jars"
for h in hadoop1 hadoop2 hadoop3; do
  ssh ${SSH_OPTS} "common@${h}" "test -s '${HUDI_JAR}' && ls -lh '${HUDI_JAR}'"
done
