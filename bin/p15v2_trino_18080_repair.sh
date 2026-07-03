#!/usr/bin/env bash
# Start and verify a temporary Trino coordinator on 18080 for P15v2.
set -uo pipefail

REMOTE_ROOT=${REMOTE_ROOT:-/home/common/tmp/finance_bigdata_project}
REPAIR_NAME=${REPAIR_NAME:-p15v2_service_repair_20260703_015213}
RUN_DIR="$REMOTE_ROOT/runs/$REPAIR_NAME"
mkdir -p "$RUN_DIR"

export JAVA_HOME=/export/server/jdk25
export PATH=/usr/local/bin:/export/server/trino/bin:$JAVA_HOME/bin:$PATH

status="$RUN_DIR/trino_18080_repair.tsv"
echo -e "check\tstatus\tdetail" > "$status"

record() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$status"
}

capture() {
  local name="$1"
  shift
  local out="$RUN_DIR/${name}.out"
  if timeout 45 "$@" > "$out" 2>&1; then
    record "$name" "PASS" "$out"
  else
    record "$name" "FAIL" "$out"
  fi
}

find_trino_cli() {
  for candidate in /usr/local/bin/trino /export/server/trino/bin/trino /export/packages/trino-cli-481; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

TEMP_ETC="$RUN_DIR/trino_18080_etc"
TEMP_DATA="$RUN_DIR/trino_18080_data"
rm -rf "$TEMP_ETC" "$TEMP_DATA"
cp -R /export/server/trino/etc "$TEMP_ETC"
mkdir -p "$TEMP_DATA"

python3 - "$TEMP_ETC/config.properties" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
values = {
    "coordinator": "true",
    "node-scheduler.include-coordinator": "true",
    "http-server.http.port": "18080",
    "discovery.uri": "http://hadoop1:18080",
}
lines = path.read_text(encoding="utf-8").splitlines()
seen = set()
out = []
for line in lines:
    key = line.split("=", 1)[0].strip() if "=" in line and not line.lstrip().startswith("#") else None
    if key in values:
        out.append(f"{key}={values[key]}")
        seen.add(key)
    else:
        out.append(line)
for key, value in values.items():
    if key not in seen:
        out.append(f"{key}={value}")
path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY

capture trino_8080_18080_before bash -lc "ss -lntp | egrep ':(8080|18080)\\b' || true"
capture trino_temp_config bash -lc "grep -nE 'coordinator|node-scheduler.include-coordinator|http-server.http.port|discovery.uri' '$TEMP_ETC/config.properties'"
capture trino_temp_start /export/server/trino/bin/launcher -etc-dir "$TEMP_ETC" -data-dir "$TEMP_DATA" start
sleep 25
capture trino_temp_status /export/server/trino/bin/launcher -etc-dir "$TEMP_ETC" -data-dir "$TEMP_DATA" status
capture trino_18080_port bash -lc "ss -lntp | grep ':18080' || true"
capture trino_18080_info curl -fsS --max-time 8 http://hadoop1:18080/v1/info

TRINO_CLI=$(find_trino_cli || true)
if [ -z "$TRINO_CLI" ]; then
  echo "Trino CLI missing" > "$RUN_DIR/trino_cli_path.out"
  record trino_cli_path FAIL "$RUN_DIR/trino_cli_path.out"
else
  echo "$TRINO_CLI" > "$RUN_DIR/trino_cli_path.out"
  record trino_cli_path PASS "$RUN_DIR/trino_cli_path.out"
  capture trino_nodes "$TRINO_CLI" --server http://hadoop1:18080 --output-format TSV_HEADER --execute "SELECT node_id,http_uri,node_version,coordinator,state FROM system.runtime.nodes"
  capture trino_iceberg_schemas "$TRINO_CLI" --server http://hadoop1:18080 --output-format TSV_HEADER --execute "SHOW SCHEMAS FROM iceberg"
  capture trino_dws_account_risk_count "$TRINO_CLI" --server http://hadoop1:18080 --output-format TSV_HEADER --execute "SELECT COUNT(*) AS cnt FROM iceberg.finance_bigdata.dws_account_risk_features"
fi

echo "P15V2_TRINO_18080_REPAIR_REMOTE_DIR=$RUN_DIR"
