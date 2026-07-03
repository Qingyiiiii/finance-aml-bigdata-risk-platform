set -euo pipefail

source /etc/profile.d/bigdata.sh 2>/dev/null || true
export JAVA_HOME=/export/server/jdk17
export PATH=/export/server/spark/bin:/export/server/hadoop/bin:/export/server/hadoop/sbin:$JAVA_HOME/bin:$PATH

DEEQU_VERSION=3.0.3-spark-3.5
DEEQU_JAR="deequ-${DEEQU_VERSION}.jar"
DEEQU_URL="https://repo.maven.apache.org/maven2/com/amazon/deequ/deequ/${DEEQU_VERSION}/${DEEQU_JAR}"
DEEQU_DIR="/export/packages/deequ"
DEEQU_PROJECT="/home/common/tmp/finance_bigdata_project/v2_quality/deequ"

SODA_VENV="/export/server/venv/soda"
SODA_PROJECT="/home/common/tmp/finance_bigdata_project/v2_quality/soda"

echo "[deequ-soda] host=$(hostname) user=$(whoami)"

echo "[deequ] prepare directories"
sudo mkdir -p "${DEEQU_DIR}" "${DEEQU_PROJECT}"
sudo chown -R common:common "${DEEQU_DIR}" "${DEEQU_PROJECT}"

echo "[deequ] download ${DEEQU_URL}"
if [ ! -s "${DEEQU_DIR}/${DEEQU_JAR}" ]; then
  curl -fL --retry 3 --retry-delay 5 "${DEEQU_URL}" -o "${DEEQU_DIR}/${DEEQU_JAR}"
else
  echo "[deequ] exists ${DEEQU_DIR}/${DEEQU_JAR}"
fi

echo "[deequ] save compatibility note"
cat > "${DEEQU_PROJECT}/compatibility_status.txt" <<EOF
component=Deequ
status=installed_backup_not_main_validation
deequ_version=${DEEQU_VERSION}
spark_version=3.5.8
scala_version=2.12.18
jar=${DEEQU_DIR}/${DEEQU_JAR}
main_validation=false
note=Installed as a backup data quality component. It is not copied into Spark default jars and is not wired into V2 P17 main acceptance.
EOF

echo "[deequ] validation"
test -s "${DEEQU_DIR}/${DEEQU_JAR}"
ls -lh "${DEEQU_DIR}/${DEEQU_JAR}"
jar tf "${DEEQU_DIR}/${DEEQU_JAR}" | grep -E 'com/amazon/deequ/(VerificationSuite|checks/Check)' | sed -n '1,10p'

echo "[soda] prepare venv and directories"
sudo mkdir -p /export/server/venv "${SODA_PROJECT}"
sudo chown -R common:common /export/server/venv "${SODA_PROJECT}"

if [ ! -f "${SODA_VENV}/pyvenv.cfg" ]; then
  python3.11 -m venv "${SODA_VENV}"
else
  echo "[soda] venv exists ${SODA_VENV}"
fi

"${SODA_VENV}/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
"${SODA_VENV}/bin/python" -m pip install -U pip wheel setuptools
"${SODA_VENV}/bin/python" -m pip install -U soda-core

cat > "${SODA_PROJECT}/finance_v2_soda_checks.yml" <<'EOF'
checks for finance_transactions_sample:
  - row_count > 0
  - missing_count(transaction_id) = 0
  - missing_count(account_number) = 0
EOF

cat > "${SODA_PROJECT}/status.txt" <<'EOF'
component=Soda
status=installed_backup_not_main_validation
main_validation=false
note=Installed as a backup data quality CLI/library. It is not wired into V2 P17 main acceptance.
EOF

echo "[soda] validation"
"${SODA_VENV}/bin/soda" --help | sed -n '1,20p'
"${SODA_VENV}/bin/python" - <<'PY'
import importlib.metadata

print("soda-core=" + importlib.metadata.version("soda-core"))
PY

echo "[deequ-soda] done"
