set -euo pipefail

DEEQU_VERSION=3.0.3-spark-3.5
DEEQU_JAR="/export/packages/deequ/deequ-${DEEQU_VERSION}.jar"
DEEQU_PROJECT="/home/common/tmp/finance_bigdata_project/v2_quality/deequ"
SODA_VENV="/export/server/venv/soda"
SODA_PROJECT="/home/common/tmp/finance_bigdata_project/v2_quality/soda"

echo "[deequ-soda-postcheck] deequ jar"
test -s "${DEEQU_JAR}"
ls -lh "${DEEQU_JAR}"
grep -E '^(component|status|deequ_version|spark_version|main_validation)=' "${DEEQU_PROJECT}/compatibility_status.txt"

echo "[deequ-soda-postcheck] soda"
"${SODA_VENV}/bin/python" --version
"${SODA_VENV}/bin/soda" --help | sed -n '1,20p'
"${SODA_VENV}/bin/python" - <<'PY'
import importlib.metadata
print("soda-core=" + importlib.metadata.version("soda-core"))
PY
grep -E '^(component|status|main_validation)=' "${SODA_PROJECT}/status.txt"

echo "[deequ-soda-postcheck] files"
find "${DEEQU_PROJECT}" "${SODA_PROJECT}" -maxdepth 2 -type f | sort
