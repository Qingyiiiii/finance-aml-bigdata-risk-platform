#!/usr/bin/env bash
# P15v2 modular restart readiness. This script checks V2 modules and writes
# evidence; it does not rebuild business data or rerun P11v2/P12v2/P13v2.
set -uo pipefail

REMOTE_ROOT=${REMOTE_ROOT:-/home/common/tmp/finance_bigdata_project}
RUN_STAMP=${RUN_STAMP:-$(date +%Y%m%d_%H%M%S)}
RUN_NAME="p15v2_modular_restart_readiness_${RUN_STAMP}"
RUN_DIR="$REMOTE_ROOT/runs/$RUN_NAME"
mkdir -p "$RUN_DIR"

export JAVA17_HOME=/export/server/jdk17
export JAVA25_HOME=/export/server/jdk25
export PATH=/usr/local/bin:/export/server/hadoop/bin:/export/server/hadoop/sbin:/export/server/hive/bin:/export/server/kafka/bin:/export/server/flink/bin:/export/server/trino/bin:/export/server/hbase/bin:$JAVA17_HOME/bin:$PATH

CREDENTIALS_FILE="$(mktemp /tmp/finance_p15v2_credentials.XXXXXX)"
cleanup_credentials() {
  shred -u "$CREDENTIALS_FILE" >/dev/null 2>&1 || rm -f "$CREDENTIALS_FILE"
}
trap cleanup_credentials EXIT
chmod 600 "$CREDENTIALS_FILE"
if [ ! -t 0 ]; then
  cat > "$CREDENTIALS_FILE"
fi
if [ -s "$CREDENTIALS_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$CREDENTIALS_FILE"
  set +a
fi

ES_PASSWORD="${ELASTICSEARCH_ELASTIC_PASSWORD:-}"
ATLAS_USER="${ATLAS_ADMIN_USERNAME:-admin}"
ATLAS_PASSWORD="${ATLAS_ADMIN_PASSWORD:-}"
ES_CA="/export/server/elasticsearch/config/certs/ca/ca.crt"
TRINO_SERVER="${TRINO_SERVER:-http://hadoop1:8080}"

BASE_TABLES=(
  "dwd_finance_transactions:5078345"
  "dwd_finance_accounts:518581"
  "dwd_finance_transaction_events:10156690"
  "dws_minute_transaction_kpi:88316"
  "dws_account_risk_features:515080"
  "dws_payment_format_kpi:7"
  "dws_large_transaction_candidates:200403"
)

write_header() {
  local path="$1"
  local header="$2"
  printf '%s\n' "$header" > "$path"
}

status_line() {
  local path="$1"
  shift
  printf '%s\n' "$*" >> "$path"
}

step() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RUN_DIR/steps.tsv"
}

kv_status() {
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >> "$RUN_DIR/$1"
}

bool_status() {
  if [ "$1" = "0" ]; then
    printf 'PASS'
  else
    printf 'FAIL'
  fi
}

no_fail_status() {
  local file
  for file in "$@"; do
    if grep -q $'\tFAIL\t' "$RUN_DIR/$file" 2>/dev/null || grep -q $'\tFAIL$' "$RUN_DIR/$file" 2>/dev/null; then
      printf 'FAIL'
      return 0
    fi
  done
  printf 'PASS'
}

safe_run() {
  local name="$1"
  local out="$2"
  shift 2
  if "$@" > "$RUN_DIR/$out" 2>&1; then
    step "$name" "PASS" "$RUN_DIR/$out"
    return 0
  fi
  step "$name" "FAIL" "$RUN_DIR/$out"
  return 1
}

bounded_ssh() {
  local host="$1"
  shift
  timeout --kill-after=5s 15s ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o ServerAliveInterval=3 \
    -o ServerAliveCountMax=1 \
    -n common@"$host" "$@"
}

json_value() {
  local file="$1"
  local key="$2"
  python3 - "$file" "$key" <<'PY' 2>/dev/null || true
import json
import sys
path, key = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path, encoding="utf-8"))
    value = data
    for part in key.split("."):
        value = value[part]
    print(value)
except Exception:
    pass
PY
}

find_trino_cli() {
  for candidate in /usr/local/bin/trino /export/server/trino/bin/trino /export/server/trino-481/client/trino-cli /export/server/trino-481/client/trino-client; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

run_trino() {
  local name="$1"
  local sql="$2"
  local out="$RUN_DIR/${name}.tsv"
  local err="$RUN_DIR/${name}.err"
  if [ -z "${TRINO_CLI:-}" ]; then
    printf 'Trino CLI missing\n' > "$err"
    printf '%s\tFAIL\t0\t%s\n' "$name" "$err" >> "$RUN_DIR/p12v2_query_module_status.tsv"
    return 1
  fi
  if timeout --kill-after=10s 90s "$TRINO_CLI" --server "$TRINO_SERVER" --output-format TSV_HEADER --execute "$sql" > "$out" 2> "$err"; then
    local rows
    rows=$(($(wc -l < "$out" 2>/dev/null || echo 1) - 1))
    if [ "$rows" -lt 0 ]; then rows=0; fi
    printf '%s\tPASS\t%s\t%s\n' "$name" "$rows" "$out" >> "$RUN_DIR/p12v2_query_module_status.tsv"
    return 0
  fi
  printf '%s\tFAIL\t0\t%s\n' "$name" "$err" >> "$RUN_DIR/p12v2_query_module_status.tsv"
  return 1
}

start_hbase_if_needed() {
  for host in hadoop1 hadoop2 hadoop3; do
    bounded_ssh "$host" "/export/server/zookeeper/bin/zkServer.sh start >/tmp/p15v2_zk_start.out 2>&1 || true" >> "$RUN_DIR/hbase_start.out" 2>&1 || true
  done
  sleep 8
  if ! jps -l | grep -q 'org.apache.hadoop.hbase.master.HMaster'; then
    timeout --kill-after=10s 60s /export/server/hbase/bin/start-hbase.sh >> "$RUN_DIR/hbase_start.out" 2>&1 || true
    timeout --kill-after=10s 45s /export/server/hbase/bin/hbase-daemon.sh start master >> "$RUN_DIR/hbase_start.out" 2>&1 || true
    sleep 20
  else
    echo "HBase master already running" >> "$RUN_DIR/hbase_start.out"
  fi
  for host in hadoop2 hadoop3; do
    bounded_ssh "$host" "/export/server/hbase/bin/hbase-daemon.sh start regionserver >/tmp/p15v2_hbase_regionserver_start.out 2>&1 || true" >> "$RUN_DIR/hbase_start.out" 2>&1 || true
  done
}

start_trino_if_needed() {
  echo "===== start/check p15v2 temp trino coordinator =====" > "$RUN_DIR/trino_launcher_status.txt"
  if curl -fsS --max-time 5 "http://hadoop1:18080/v1/info" > "$RUN_DIR/trino_18080_info.json" 2>> "$RUN_DIR/trino_launcher_status.txt"; then
    echo "Temp Trino coordinator already reachable on 18080" >> "$RUN_DIR/trino_launcher_status.txt"
    TRINO_SERVER="http://hadoop1:18080"
    return 0
  fi
  TEMP_TRINO_ETC="$RUN_DIR/trino_etc"
  TEMP_TRINO_DATA="$RUN_DIR/trino_data"
  rm -rf "$TEMP_TRINO_ETC" "$TEMP_TRINO_DATA"
  cp -R /export/server/trino/etc "$TEMP_TRINO_ETC"
  mkdir -p "$TEMP_TRINO_DATA"
  python3 - "$TEMP_TRINO_ETC/config.properties" <<'PY'
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
  {
    echo "===== existing hadoop1 port 8080/18080 before ====="
    ss -lntp | egrep '8080|18080' || true
    echo "===== temp config ====="
    grep -nE 'coordinator|node-scheduler.include-coordinator|http-server.http.port|discovery.uri' "$TEMP_TRINO_ETC/config.properties" || true
    echo "===== start temp coordinator ====="
    timeout --kill-after=10s 75s /export/server/trino/bin/launcher -etc-dir "$TEMP_TRINO_ETC" -data-dir "$TEMP_TRINO_DATA" start || true
  } >> "$RUN_DIR/trino_launcher_status.txt" 2>&1
  sleep 15
  {
    echo "===== temp status after ====="
    timeout --kill-after=5s 20s /export/server/trino/bin/launcher -etc-dir "$TEMP_TRINO_ETC" -data-dir "$TEMP_TRINO_DATA" status || true
    ss -lntp | egrep '8080|18080' || true
    tail -n 120 "$TEMP_TRINO_DATA/var/log/server.log" 2>/dev/null || true
  } >> "$RUN_DIR/trino_launcher_status.txt" 2>&1
  TRINO_SERVER="http://hadoop1:18080"
}

snapshot_nodes() {
  local phase="$1"
  local out="$RUN_DIR/node_snapshot_${phase}.tsv"
  write_header "$out" "phase	node	hostname	ip_summary	load_or_memory	disk_export	jps_summary"
  for host in hadoop1 hadoop2 hadoop3; do
    bounded_ssh "$host" "bash -lc '
      hn=\$(hostname 2>/dev/null || echo unknown)
      ip=\$(hostname -I 2>/dev/null | tr \" \" \",\" | sed \"s/,\$//\")
      mem=\$(free -h 2>/dev/null | awk \"/^Mem:/ {print \\\"total=\\\"\\\$2\\\",used=\\\"\\\$3\\\",free=\\\"\\\$4}\")
      disk=\$(df -h /export 2>/dev/null | awk \"NR==2 {print \\\"size=\\\"\\\$2\\\",used=\\\"\\\$3\\\",avail=\\\"\\\$4\\\",use=\\\"\\\$5}\")
      jps=\$(jps -l 2>/dev/null | awk \"{print \\\$2}\" | paste -sd \",\" -)
      printf \"%s\t%s\t%s\t%s\t%s\t%s\t%s\n\" \"$phase\" \"$host\" \"\$hn\" \"\$ip\" \"\$mem\" \"\$disk\" \"\$jps\"
    '" >> "$out" 2>/dev/null || printf '%s\t%s\tERROR\tERROR\tERROR\tERROR\tERROR\n' "$phase" "$host" >> "$out"
  done
}

snapshot_resources() {
  local phase="$1"
  local out="$RUN_DIR/resource_usage_snapshots.tsv"
  if [ ! -s "$out" ]; then
    write_header "$out" "phase	node	memory	disk_export	yarn_running_apps	flink_running_jobs"
  fi
  local yarn_count flink_count
  timeout --kill-after=5s 25s yarn application -list -appStates RUNNING > "$RUN_DIR/yarn_running_${phase}.out" 2>&1 || true
  yarn_count=$(sed -n 's/.*):\([0-9][0-9]*\).*/\1/p' "$RUN_DIR/yarn_running_${phase}.out" | tail -n 1)
  yarn_count=${yarn_count:-UNKNOWN}
  timeout --kill-after=5s 25s /export/server/flink/bin/flink list -r > "$RUN_DIR/flink_running_${phase}.out" 2>&1 || true
  if grep -q 'No running jobs' "$RUN_DIR/flink_running_${phase}.out"; then
    flink_count=0
  else
    flink_count=$(grep -Ec '[0-9a-f]{32}' "$RUN_DIR/flink_running_${phase}.out" || true)
  fi
  for host in hadoop1 hadoop2 hadoop3; do
    bounded_ssh "$host" "bash -lc '
      mem=\$(free -h 2>/dev/null | awk \"/^Mem:/ {print \\\"total=\\\"\\\$2\\\",used=\\\"\\\$3\\\",free=\\\"\\\$4}\")
      disk=\$(df -h /export 2>/dev/null | awk \"NR==2 {print \\\"size=\\\"\\\$2\\\",used=\\\"\\\$3\\\",avail=\\\"\\\$4\\\",use=\\\"\\\$5}\")
      printf \"%s\t%s\t%s\t%s\t%s\t%s\n\" \"$phase\" \"$host\" \"\$mem\" \"\$disk\" \"$yarn_count\" \"$flink_count\"
    '" >> "$out" 2>/dev/null || printf '%s\t%s\tERROR\tERROR\t%s\t%s\n' "$phase" "$host" "$yarn_count" "$flink_count" >> "$out"
  done
}

scan_ports() {
  local out="$RUN_DIR/port_binding_scan.tsv"
  write_header "$out" "node	port	local_address	status	detail"
  local ports='8123|9000|9200|9300|6080|5151|21000|2182|9838|9026|9027|9090|3000|19200|19300'
  for host in hadoop1 hadoop2 hadoop3; do
    local host_out="$RUN_DIR/port_binding_${host}.out"
    if ! bounded_ssh "$host" "ss -lntp 2>/dev/null | awk '\$4 ~ /:($ports)$/ {print \$4}'" > "$host_out" 2>/dev/null; then
      printf '%s\tNA\tNA\tFAIL\tssh_or_ss_timeout\n' "$host" >> "$out"
      continue
    fi
    while read -r address; do
      [ -z "$address" ] && continue
      port="${address##*:}"
      status="PASS"
      detail="bound_to_specific_or_loopback"
      if printf '%s\n' "$address" | grep -Eq '(^|:)0\.0\.0\.0:|^\*:|\[::\]:'; then
        status="FAIL"
        detail="wildcard_listener_detected"
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$host" "$port" "$address" "$status" "$detail" >> "$out"
    done < "$host_out"
  done
}

write_header "$RUN_DIR/steps.tsv" "step	status	detail"
write_header "$RUN_DIR/base_platform_status.tsv" "check	status	value	detail"
write_header "$RUN_DIR/iceberg_table_counts.tsv" "table_name	expected_count	actual_count	status"
write_header "$RUN_DIR/p11v2_realtime_module_status.tsv" "check	status	value	detail"
write_header "$RUN_DIR/hbase_readiness.tsv" "check	status	value	detail"
write_header "$RUN_DIR/p12v2_query_module_status.tsv" "check	status	value	detail"
write_header "$RUN_DIR/clickhouse_readiness.tsv" "check	status	value	detail"
write_header "$RUN_DIR/elasticsearch_readiness.tsv" "check	status	value	detail"
write_header "$RUN_DIR/governance_module_status.tsv" "check	status	value	detail"
write_header "$RUN_DIR/ranger_readiness.tsv" "check	status	value	detail"
write_header "$RUN_DIR/atlas_readiness.tsv" "check	status	value	detail"
write_header "$RUN_DIR/monitoring_module_status.tsv" "check	status	value	detail"
write_header "$RUN_DIR/prometheus_grafana_readiness.tsv" "check	status	value	detail"
write_header "$RUN_DIR/backup_components_status.tsv" "check	status	value	detail"
write_header "$RUN_DIR/postcheck.tsv" "check	status	value	detail"

snapshot_nodes "before"
snapshot_resources "before"
step "snapshot_before" "PASS" "$RUN_DIR/node_snapshot_before.tsv"

# Base platform.
if safe_run "hdfs_ls" "hdfs_finance_ls.out" timeout 25s hdfs dfs -ls /lakehouse/projects/finance_bigdata; then
  kv_status base_platform_status.tsv hdfs_project_root PASS readable /lakehouse/projects/finance_bigdata
else
  kv_status base_platform_status.tsv hdfs_project_root FAIL unreadable "$RUN_DIR/hdfs_finance_ls.out"
fi

timeout --kill-after=5s 25s yarn node -list > "$RUN_DIR/yarn_nodes.out" 2>&1 || true
yarn_nodes=$(grep -c 'RUNNING' "$RUN_DIR/yarn_nodes.out" || true)
if [ "$yarn_nodes" -ge 3 ]; then
  kv_status base_platform_status.tsv yarn_nodes PASS "$yarn_nodes" "running nodes"
else
  kv_status base_platform_status.tsv yarn_nodes FAIL "$yarn_nodes" "$RUN_DIR/yarn_nodes.out"
fi

if timeout 45s /export/server/hive/bin/beeline -u "jdbc:hive2://hadoop1:10000/default" -n common -e "SHOW DATABASES LIKE 'finance_bigdata';" > "$RUN_DIR/beeline_finance_database.out" 2>&1 && grep -q 'finance_bigdata' "$RUN_DIR/beeline_finance_database.out"; then
  kv_status base_platform_status.tsv hive_finance_database PASS finance_bigdata "visible via beeline"
else
  kv_status base_platform_status.tsv hive_finance_database FAIL missing "$RUN_DIR/beeline_finance_database.out"
fi

export JAVA_HOME=/export/server/jdk17
SPARK_ARGS=(
  --conf spark.executor.instances=1
  --conf spark.executor.cores=1
  --conf spark.executor.memory=512m
  --conf spark.executor.memoryOverhead=256m
  --conf spark.driver.memory=512m
  --conf spark.driver.bindAddress=CLUSTER_NODE1_IP
  --conf spark.driver.host=hadoop1
  --conf spark.driver.port=37211
  --conf spark.blockManager.port=37212
  --conf spark.sql.shuffle.partitions=2
)
timeout --kill-after=10s 90s spark-sql "${SPARK_ARGS[@]}" -e "SHOW TABLES IN lakehouse.finance_bigdata;" > "$RUN_DIR/spark_show_tables.out" 2>&1 || true
if grep -q 'dwd_finance_transactions' "$RUN_DIR/spark_show_tables.out"; then
  kv_status base_platform_status.tsv iceberg_namespace PASS lakehouse.finance_bigdata "visible via spark"
else
  kv_status base_platform_status.tsv iceberg_namespace FAIL missing "$RUN_DIR/spark_show_tables.out"
fi

{
  first=1
  for pair in "${BASE_TABLES[@]}"; do
    table="${pair%%:*}"
    if [ "$first" = "1" ]; then
      first=0
    else
      printf 'UNION ALL\n'
    fi
    printf "SELECT '%s' AS table_name, COUNT(*) AS actual_count FROM lakehouse.finance_bigdata.%s\n" "$table" "$table"
  done
  printf ';\n'
} > "$RUN_DIR/spark_table_counts.sql"
timeout --kill-after=10s 240s spark-sql "${SPARK_ARGS[@]}" -S -f "$RUN_DIR/spark_table_counts.sql" > "$RUN_DIR/spark_table_counts_raw.out" 2> "$RUN_DIR/spark_table_counts.err" || true
for pair in "${BASE_TABLES[@]}"; do
  table="${pair%%:*}"
  expected="${pair##*:}"
  actual=$(awk -v table="$table" '$1==table {v=$2} END {print v}' "$RUN_DIR/spark_table_counts_raw.out" 2>/dev/null)
  actual=${actual:-0}
  if [ "$actual" = "$expected" ]; then
    status="PASS"
  else
    status="FAIL"
  fi
  printf '%s\t%s\t%s\t%s\n' "$table" "$expected" "$actual" "$status" >> "$RUN_DIR/iceberg_table_counts.tsv"
done
step "base_platform_check" "$(no_fail_status base_platform_status.tsv iceberg_table_counts.tsv)" "$RUN_DIR/base_platform_status.tsv"

# P11v2 realtime state module.
start_hbase_if_needed
step "start_or_confirm_hbase" "PASS" "$RUN_DIR/hbase_start.out"

timeout --kill-after=5s 25s /export/server/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server CLUSTER_NODE1_IP:9092 describe --status > "$RUN_DIR/kafka_quorum.out" 2>&1 || true
if grep -q 'CurrentVoters' "$RUN_DIR/kafka_quorum.out"; then
  kv_status p11v2_realtime_module_status.tsv kafka_quorum PASS current_voters "$RUN_DIR/kafka_quorum.out"
else
  kv_status p11v2_realtime_module_status.tsv kafka_quorum FAIL missing "$RUN_DIR/kafka_quorum.out"
fi

redis_ping=$(redis-cli -h 127.0.0.1 ping 2>/dev/null || true)
if [ "$redis_ping" = "PONG" ]; then
  kv_status p11v2_realtime_module_status.tsv redis_ping PASS PONG "Redis cache reachable"
else
  kv_status p11v2_realtime_module_status.tsv redis_ping FAIL "$redis_ping" "Redis ping failed"
fi

timeout --kill-after=5s 25s /export/server/flink/bin/flink list -r > "$RUN_DIR/flink_running_jobs.out" 2>&1 || true
if grep -q 'No running jobs' "$RUN_DIR/flink_running_jobs.out"; then
  kv_status p11v2_realtime_module_status.tsv flink_running_jobs PASS 0 "No running jobs"
else
  running_jobs=$(grep -Ec '[0-9a-f]{32}' "$RUN_DIR/flink_running_jobs.out" || true)
  kv_status p11v2_realtime_module_status.tsv flink_running_jobs FAIL "$running_jobs" "$RUN_DIR/flink_running_jobs.out"
fi

if jps -l | grep -q 'StandaloneSessionClusterEntrypoint'; then
  kv_status p11v2_realtime_module_status.tsv flink_service PASS jobmanager "process exists"
else
  kv_status p11v2_realtime_module_status.tsv flink_service FAIL missing "JobManager process missing"
fi

for host in hadoop1 hadoop2 hadoop3; do
  bounded_ssh "$host" "/export/server/zookeeper/bin/zkServer.sh status; jps -l | egrep 'QuorumPeerMain|HMaster|HRegionServer' || true" >> "$RUN_DIR/hbase_process_snapshot.txt" 2>&1 || true
done
timeout --kill-after=10s 75s /export/server/hbase/bin/hbase shell -n > "$RUN_DIR/hbase_readiness.out" 2>&1 <<'HBASE'
status 'simple'
list_namespace
exists 'finance_bigdata_v2:account_risk_state'
scan 'finance_bigdata_v2:account_risk_state', {LIMIT => 1}
HBASE
if grep -q 'active master' "$RUN_DIR/hbase_readiness.out" || grep -q 'active master,' "$RUN_DIR/hbase_readiness.out"; then
  kv_status hbase_readiness.tsv hbase_status PASS active_master "$RUN_DIR/hbase_readiness.out"
else
  kv_status hbase_readiness.tsv hbase_status FAIL unknown "$RUN_DIR/hbase_readiness.out"
fi
if grep -q 'finance_bigdata_v2' "$RUN_DIR/hbase_readiness.out"; then
  kv_status hbase_readiness.tsv hbase_namespace PASS finance_bigdata_v2 "namespace visible"
else
  kv_status hbase_readiness.tsv hbase_namespace FAIL missing "namespace missing"
fi
if grep -q 'Table finance_bigdata_v2:account_risk_state does exist' "$RUN_DIR/hbase_readiness.out"; then
  kv_status hbase_readiness.tsv hbase_state_table PASS finance_bigdata_v2:account_risk_state "table exists"
else
  kv_status hbase_readiness.tsv hbase_state_table FAIL missing "table missing"
fi
if grep -Eq 'column=state:' "$RUN_DIR/hbase_readiness.out"; then
  kv_status hbase_readiness.tsv hbase_sample_read PASS nonempty "sample row visible"
else
  kv_status hbase_readiness.tsv hbase_sample_read FAIL empty "sample scan returned no state cells"
fi
step "p11v2_realtime_module_check" "$(no_fail_status p11v2_realtime_module_status.tsv hbase_readiness.tsv)" "$RUN_DIR/p11v2_realtime_module_status.tsv"

# P12v2 query and search module.
start_trino_if_needed
step "start_or_confirm_trino" "PASS" "$RUN_DIR/trino_launcher_status.txt"
TRINO_CLI=$(find_trino_cli || true)
printf 'TRINO_CLI=%s\n' "$TRINO_CLI" > "$RUN_DIR/trino_cli_path.txt"
if [ -n "$TRINO_CLI" ]; then
  run_trino trino_nodes "SELECT node_id, http_uri, node_version, coordinator, state FROM system.runtime.nodes ORDER BY node_id;" || true
  run_trino trino_finance_schema "SHOW SCHEMAS FROM iceberg LIKE 'finance_bigdata';" || true
  run_trino trino_account_risk_count "SELECT COUNT(*) AS row_count FROM iceberg.finance_bigdata.dws_account_risk_features;" || true
else
  printf '%s\tFAIL\t0\t%s\n' "trino_cli" "$RUN_DIR/trino_cli_path.txt" >> "$RUN_DIR/p12v2_query_module_status.tsv"
fi

if timeout --kill-after=5s 15s clickhouse-client --query "SELECT version() AS version FORMAT TabSeparatedWithNames" > "$RUN_DIR/clickhouse_version.tsv" 2> "$RUN_DIR/clickhouse_version.err"; then
  kv_status clickhouse_readiness.tsv clickhouse_service PASS reachable "$RUN_DIR/clickhouse_version.tsv"
else
  kv_status clickhouse_readiness.tsv clickhouse_service FAIL unreachable "$RUN_DIR/clickhouse_version.err"
fi
timeout --kill-after=5s 15s clickhouse-client --query "SHOW DATABASES LIKE 'finance_bigdata_v2' FORMAT TabSeparatedWithNames" > "$RUN_DIR/clickhouse_database.tsv" 2> "$RUN_DIR/clickhouse_database.err" || true
if grep -q 'finance_bigdata_v2' "$RUN_DIR/clickhouse_database.tsv"; then
  kv_status clickhouse_readiness.tsv clickhouse_database PASS finance_bigdata_v2 "database visible"
else
  kv_status clickhouse_readiness.tsv clickhouse_database FAIL missing "$RUN_DIR/clickhouse_database.err"
fi
timeout --kill-after=5s 15s clickhouse-client --query "SHOW TABLES FROM finance_bigdata_v2 LIKE 'ads_account_risk_features' FORMAT TabSeparatedWithNames" > "$RUN_DIR/clickhouse_tables.tsv" 2> "$RUN_DIR/clickhouse_tables.err" || true
if grep -q 'ads_account_risk_features' "$RUN_DIR/clickhouse_tables.tsv"; then
  kv_status clickhouse_readiness.tsv clickhouse_ads_table PASS ads_account_risk_features "table visible"
else
  kv_status clickhouse_readiness.tsv clickhouse_ads_table FAIL missing "$RUN_DIR/clickhouse_tables.err"
fi
timeout --kill-after=5s 20s clickhouse-client --query "SELECT count() AS row_count FROM finance_bigdata_v2.ads_account_risk_features FORMAT TabSeparatedWithNames" > "$RUN_DIR/clickhouse_ads_count.tsv" 2> "$RUN_DIR/clickhouse_ads_count.err" || true
ads_count=$(awk 'NR==2 {print $1}' "$RUN_DIR/clickhouse_ads_count.tsv" 2>/dev/null || echo 0)
ads_count=${ads_count:-0}
if [ "$ads_count" -gt 0 ]; then
  kv_status clickhouse_readiness.tsv clickhouse_ads_count PASS "$ads_count" "ADS rows"
else
  kv_status clickhouse_readiness.tsv clickhouse_ads_count FAIL "$ads_count" "$RUN_DIR/clickhouse_ads_count.err"
fi

if [ -n "$ES_PASSWORD" ] && [ -f "$ES_CA" ]; then
  curl -fsS --max-time 15 --cacert "$ES_CA" -u "elastic:${ES_PASSWORD}" "https://127.0.0.1:9200/_cluster/health" > "$RUN_DIR/elasticsearch_health.json" 2> "$RUN_DIR/elasticsearch_health.err" || true
  es_health=$(json_value "$RUN_DIR/elasticsearch_health.json" status)
  if [ "$es_health" = "green" ] || [ "$es_health" = "yellow" ]; then
    kv_status elasticsearch_readiness.tsv elasticsearch_health PASS "$es_health" "$RUN_DIR/elasticsearch_health.json"
  else
    kv_status elasticsearch_readiness.tsv elasticsearch_health FAIL "${es_health:-unknown}" "$RUN_DIR/elasticsearch_health.err"
  fi
  curl -fsS --max-time 15 --cacert "$ES_CA" -u "elastic:${ES_PASSWORD}" "https://127.0.0.1:9200/finance-risk-events-v2/_count" > "$RUN_DIR/elasticsearch_count.json" 2> "$RUN_DIR/elasticsearch_count.err" || true
  es_count=$(json_value "$RUN_DIR/elasticsearch_count.json" count)
  es_count=${es_count:-0}
  if [ "$es_count" -gt 0 ]; then
    kv_status elasticsearch_readiness.tsv elasticsearch_count PASS "$es_count" "index has documents"
  else
    kv_status elasticsearch_readiness.tsv elasticsearch_count FAIL "$es_count" "$RUN_DIR/elasticsearch_count.err"
  fi
  curl -fsS --max-time 15 --cacert "$ES_CA" -u "elastic:${ES_PASSWORD}" "https://127.0.0.1:9200/finance-risk-events-v2/_search?size=1&q=risk_level:HIGH" > "$RUN_DIR/elasticsearch_search_sample.json" 2> "$RUN_DIR/elasticsearch_search_sample.err" || true
  es_hits=$(python3 - "$RUN_DIR/elasticsearch_search_sample.json" <<'PY' 2>/dev/null || echo 0
import json, sys
try:
    payload = json.load(open(sys.argv[1], encoding="utf-8"))
    total = payload.get("hits", {}).get("total", {})
    print(total.get("value", 0) if isinstance(total, dict) else total)
except Exception:
    print(0)
PY
)
  if [ "${es_hits:-0}" -gt 0 ]; then
    kv_status elasticsearch_readiness.tsv elasticsearch_search PASS "$es_hits" "$RUN_DIR/elasticsearch_search_sample.json"
  else
    kv_status elasticsearch_readiness.tsv elasticsearch_search FAIL "${es_hits:-0}" "$RUN_DIR/elasticsearch_search_sample.err"
  fi
else
  kv_status elasticsearch_readiness.tsv elasticsearch_credentials FAIL missing "password or CA missing"
fi
step "p12v2_query_module_check" "$(no_fail_status p12v2_query_module_status.tsv clickhouse_readiness.tsv elasticsearch_readiness.tsv)" "$RUN_DIR/p12v2_query_module_status.tsv"

# Governance module.
ranger_active=$(systemctl is-active finance-ranger-admin 2>/dev/null || true)
if [ "$ranger_active" = "active" ]; then
  kv_status ranger_readiness.tsv ranger_admin_service PASS active "finance-ranger-admin"
else
  kv_status ranger_readiness.tsv ranger_admin_service FAIL "${ranger_active:-unknown}" "finance-ranger-admin"
fi
if curl -fsS --max-time 8 "http://CLUSTER_NODE1_IP:6080/login.jsp" > "$RUN_DIR/ranger_login.html" 2> "$RUN_DIR/ranger_login.err"; then
  kv_status ranger_readiness.tsv ranger_admin_http PASS login.jsp "reachable"
else
  kv_status ranger_readiness.tsv ranger_admin_http FAIL unreachable "$RUN_DIR/ranger_login.err"
fi
ss_6080=$(ss -lntp | awk '$4 ~ /:6080$/ {print}' || true)
printf '%s\n' "$ss_6080" > "$RUN_DIR/ranger_6080_listener.txt"
if printf '%s\n' "$ss_6080" | grep -Eq '0\.0\.0\.0:6080|\[::\]:6080|\*:6080'; then
  kv_status ranger_readiness.tsv ranger_admin_bind FAIL wildcard "$RUN_DIR/ranger_6080_listener.txt"
elif printf '%s\n' "$ss_6080" | grep -Eq '(192\.168\.88\.101:6080|\[::ffff:192\.168\.88\.101\]:6080)'; then
  kv_status ranger_readiness.tsv ranger_admin_bind PASS CLUSTER_NODE1_IP:6080 "$RUN_DIR/ranger_6080_listener.txt"
else
  kv_status ranger_readiness.tsv ranger_admin_bind FAIL missing "$RUN_DIR/ranger_6080_listener.txt"
fi
usersync_state=$(systemctl is-active finance-ranger-usersync 2>/dev/null || true)
kv_status ranger_readiness.tsv ranger_usersync_state PASS "${usersync_state:-unknown}" "inactive/disabled is acceptable"
ss_5151=$(ss -lntp | awk '$4 ~ /:5151$/ {print}' || true)
printf '%s\n' "$ss_5151" > "$RUN_DIR/ranger_5151_listener.txt"
if printf '%s\n' "$ss_5151" | grep -Eq '0\.0\.0\.0:5151|\[::\]:5151|\*:5151'; then
  kv_status ranger_readiness.tsv ranger_usersync_bind FAIL wildcard "$RUN_DIR/ranger_5151_listener.txt"
else
  kv_status ranger_readiness.tsv ranger_usersync_bind PASS none_or_safe "$RUN_DIR/ranger_5151_listener.txt"
fi

atlas_active=$(systemctl is-active finance-atlas 2>/dev/null || true)
if [ "$atlas_active" = "active" ]; then
  kv_status atlas_readiness.tsv atlas_service PASS active "finance-atlas"
else
  kv_status atlas_readiness.tsv atlas_service FAIL "${atlas_active:-unknown}" "finance-atlas"
fi
for path in /login.jsp /api/atlas/admin/status; do
  if [ "$path" = "/api/atlas/admin/status" ] && [ -n "$ATLAS_PASSWORD" ]; then
    code=$(curl -sS -u "${ATLAS_USER}:${ATLAS_PASSWORD}" -o "$RUN_DIR/atlas_status.json" -w '%{http_code}' --max-time 15 "http://CLUSTER_NODE1_IP:21000${path}" 2> "$RUN_DIR/atlas_status.err" || true)
    atlas_status=$(tr -d '\n' < "$RUN_DIR/atlas_status.json" 2>/dev/null | head -c 120)
    if [ "$code" = "200" ] && printf '%s' "$atlas_status" | grep -q 'ACTIVE'; then
      kv_status atlas_readiness.tsv atlas_admin_status PASS ACTIVE "$RUN_DIR/atlas_status.json"
    else
      kv_status atlas_readiness.tsv atlas_admin_status FAIL "code=${code}" "$RUN_DIR/atlas_status.err"
    fi
  elif [ "$path" = "/login.jsp" ]; then
    code=$(curl -sS -o "$RUN_DIR/atlas_login.html" -w '%{http_code}' --max-time 10 "http://CLUSTER_NODE1_IP:21000${path}" 2> "$RUN_DIR/atlas_login.err" || true)
    if [ "$code" = "200" ]; then
      kv_status atlas_readiness.tsv atlas_login PASS 200 "$RUN_DIR/atlas_login.html"
    else
      kv_status atlas_readiness.tsv atlas_login FAIL "code=${code}" "$RUN_DIR/atlas_login.err"
    fi
  fi
done
atlas_listeners=$(ss -ltnp | awk '$4 ~ /:(21000|9838|2182|9026|9027)$/ {print}' || true)
printf '%s\n' "$atlas_listeners" > "$RUN_DIR/atlas_listeners.txt"
if printf '%s\n' "$atlas_listeners" | grep -Eq '0\.0\.0\.0:(9838|2182|9026|9027)|\[::\]:(9838|2182|9026|9027)|\*:(9838|2182|9026|9027)'; then
  kv_status atlas_readiness.tsv atlas_embedded_bind FAIL wildcard "$RUN_DIR/atlas_listeners.txt"
else
  kv_status atlas_readiness.tsv atlas_embedded_bind PASS loopback_or_safe "$RUN_DIR/atlas_listeners.txt"
fi
if printf '%s\n' "$atlas_listeners" | grep -Eq '(192\.168\.88\.101:21000|\[::ffff:192\.168\.88\.101\]:21000)'; then
  kv_status atlas_readiness.tsv atlas_web_bind PASS CLUSTER_NODE1_IP:21000 "$RUN_DIR/atlas_listeners.txt"
else
  kv_status atlas_readiness.tsv atlas_web_bind FAIL missing "$RUN_DIR/atlas_listeners.txt"
fi
step "governance_module_check" "$(no_fail_status ranger_readiness.tsv atlas_readiness.tsv)" "$RUN_DIR/governance_module_status.tsv"
awk 'NR>1 {print "ranger_"$0}' "$RUN_DIR/ranger_readiness.tsv" >> "$RUN_DIR/governance_module_status.tsv"
awk 'NR>1 {print "atlas_"$0}' "$RUN_DIR/atlas_readiness.tsv" >> "$RUN_DIR/governance_module_status.tsv"

# Monitoring module.
if curl -fsS --max-time 8 "http://CLUSTER_NODE1_IP:9090/-/ready" > "$RUN_DIR/prometheus_ready.out" 2> "$RUN_DIR/prometheus_ready.err"; then
  kv_status prometheus_grafana_readiness.tsv prometheus_ready PASS ready "$RUN_DIR/prometheus_ready.out"
else
  kv_status prometheus_grafana_readiness.tsv prometheus_ready FAIL unreachable "$RUN_DIR/prometheus_ready.err"
fi
if curl -fsS --max-time 8 "http://CLUSTER_NODE1_IP:3000/login" > "$RUN_DIR/grafana_login.html" 2> "$RUN_DIR/grafana_login.err"; then
  kv_status prometheus_grafana_readiness.tsv grafana_login PASS reachable "$RUN_DIR/grafana_login.html"
else
  kv_status prometheus_grafana_readiness.tsv grafana_login FAIL unreachable "$RUN_DIR/grafana_login.err"
fi
if curl -fsS --max-time 8 "http://CLUSTER_NODE1_IP:9090/api/v1/targets" > "$RUN_DIR/prometheus_targets.json" 2> "$RUN_DIR/prometheus_targets.err"; then
  up_count=$(python3 - "$RUN_DIR/prometheus_targets.json" <<'PY' 2>/dev/null || echo 0
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    active = data.get("data", {}).get("activeTargets", [])
    print(sum(1 for t in active if t.get("health") == "up"))
except Exception:
    print(0)
PY
)
  if [ "${up_count:-0}" -ge 2 ]; then
    kv_status prometheus_grafana_readiness.tsv prometheus_targets PASS "$up_count" "active targets up"
  else
    kv_status prometheus_grafana_readiness.tsv prometheus_targets FAIL "${up_count:-0}" "$RUN_DIR/prometheus_targets.json"
  fi
else
  kv_status prometheus_grafana_readiness.tsv prometheus_targets FAIL unreachable "$RUN_DIR/prometheus_targets.err"
fi
if [ -f /export/server/grafana/data/dashboards/finance_bigdata_v2/finance_bigdata_v2_overview.json ]; then
  kv_status prometheus_grafana_readiness.tsv grafana_dashboard PASS present "/export/server/grafana/data/dashboards/finance_bigdata_v2/finance_bigdata_v2_overview.json"
else
  kv_status prometheus_grafana_readiness.tsv grafana_dashboard FAIL missing "dashboard json missing"
fi
step "monitoring_module_check" "$(no_fail_status prometheus_grafana_readiness.tsv)" "$RUN_DIR/prometheus_grafana_readiness.tsv"
awk 'NR>1 {print $0}' "$RUN_DIR/prometheus_grafana_readiness.tsv" >> "$RUN_DIR/monitoring_module_status.tsv"

# Backup components.
if [ -x /export/server/opensearch/bin/opensearch ]; then
  os_version=$(timeout --kill-after=5s 15s /export/server/opensearch/bin/opensearch --version 2>/dev/null | head -n 1)
  kv_status backup_components_status.tsv opensearch_installed PASS present "${os_version:-version_unknown}"
else
  kv_status backup_components_status.tsv opensearch_installed FAIL missing "/export/server/opensearch"
fi
os_listener=$(ss -lntp | grep -E ':(19200|19300)\b' || true)
printf '%s\n' "$os_listener" > "$RUN_DIR/opensearch_listener.txt"
if [ -z "$os_listener" ]; then
  kv_status backup_components_status.tsv opensearch_not_listening PASS 0 "backup only, not in main chain"
else
  kv_status backup_components_status.tsv opensearch_not_listening FAIL listening "$RUN_DIR/opensearch_listener.txt"
fi
if [ -s /export/packages/deequ/deequ-3.0.3-spark-3.5.jar ]; then
  kv_status backup_components_status.tsv deequ_jar PASS present "/export/packages/deequ/deequ-3.0.3-spark-3.5.jar"
else
  kv_status backup_components_status.tsv deequ_jar WARN missing "backup component only"
fi
if [ -x /export/server/venv/soda/bin/soda ]; then
  kv_status backup_components_status.tsv soda_venv PASS present "/export/server/venv/soda"
else
  kv_status backup_components_status.tsv soda_venv WARN missing "backup component only"
fi
step "backup_component_record" "$(no_fail_status backup_components_status.tsv)" "$RUN_DIR/backup_components_status.tsv"

snapshot_nodes "after"
snapshot_resources "after"
scan_ports
step "snapshot_after_and_port_scan" "$(no_fail_status port_binding_scan.tsv)" "$RUN_DIR/port_binding_scan.tsv"

yarn_after=$(sed -n 's/.*):\([0-9][0-9]*\).*/\1/p' "$RUN_DIR/yarn_running_after.out" | tail -n 1)
yarn_after=${yarn_after:-UNKNOWN}
if [ "$yarn_after" = "0" ]; then
  kv_status postcheck.tsv yarn_running_apps PASS 0 "$RUN_DIR/yarn_running_after.out"
else
  kv_status postcheck.tsv yarn_running_apps FAIL "$yarn_after" "$RUN_DIR/yarn_running_after.out"
fi
if grep -q 'No running jobs' "$RUN_DIR/flink_running_after.out"; then
  kv_status postcheck.tsv flink_running_jobs PASS 0 "$RUN_DIR/flink_running_after.out"
else
  flink_after=$(grep -Ec '[0-9a-f]{32}' "$RUN_DIR/flink_running_after.out" || true)
  kv_status postcheck.tsv flink_running_jobs FAIL "$flink_after" "$RUN_DIR/flink_running_after.out"
fi
if grep -q $'\tFAIL\t' "$RUN_DIR/port_binding_scan.tsv"; then
  kv_status postcheck.tsv wildcard_v2_listeners FAIL present "$RUN_DIR/port_binding_scan.tsv"
else
  kv_status postcheck.tsv wildcard_v2_listeners PASS 0 "$RUN_DIR/port_binding_scan.tsv"
fi

module_status() {
  local file="$1"
  if grep -q $'\tFAIL\t' "$RUN_DIR/$file" || grep -q $'\tFAIL$' "$RUN_DIR/$file"; then
    printf 'FAIL'
  else
    printf 'PASS'
  fi
}

base_status=$(module_status base_platform_status.tsv)
if grep -q $'\tFAIL$' "$RUN_DIR/iceberg_table_counts.tsv"; then base_status="FAIL"; fi
p11_status=$(module_status p11v2_realtime_module_status.tsv)
if [ "$(module_status hbase_readiness.tsv)" = "FAIL" ]; then p11_status="FAIL"; fi
p12_status=$(module_status p12v2_query_module_status.tsv)
if [ "$(module_status clickhouse_readiness.tsv)" = "FAIL" ] || [ "$(module_status elasticsearch_readiness.tsv)" = "FAIL" ]; then p12_status="FAIL"; fi
governance_status=$(module_status governance_module_status.tsv)
monitoring_status=$(module_status monitoring_module_status.tsv)
backup_status=$(module_status backup_components_status.tsv)
post_status=$(module_status postcheck.tsv)

p15v2_status="PASS"
for s in "$base_status" "$p11_status" "$p12_status" "$governance_status" "$monitoring_status" "$backup_status" "$post_status"; do
  if [ "$s" != "PASS" ]; then
    p15v2_status="FAIL"
  fi
done

write_header "$RUN_DIR/p15v2_status.tsv" "metric	value"
status_line "$RUN_DIR/p15v2_status.tsv" "run_name	$RUN_NAME"
status_line "$RUN_DIR/p15v2_status.tsv" "run_dir	$RUN_DIR"
status_line "$RUN_DIR/p15v2_status.tsv" "base_platform_status	$base_status"
status_line "$RUN_DIR/p15v2_status.tsv" "p11v2_realtime_module_status	$p11_status"
status_line "$RUN_DIR/p15v2_status.tsv" "p12v2_query_module_status	$p12_status"
status_line "$RUN_DIR/p15v2_status.tsv" "governance_module_status	$governance_status"
status_line "$RUN_DIR/p15v2_status.tsv" "monitoring_module_status	$monitoring_status"
status_line "$RUN_DIR/p15v2_status.tsv" "backup_components_status	$backup_status"
status_line "$RUN_DIR/p15v2_status.tsv" "postcheck_status	$post_status"
status_line "$RUN_DIR/p15v2_status.tsv" "iceberg_table_fail_count	$(awk -F '\t' '$4=="FAIL" {c++} END {print c+0}' "$RUN_DIR/iceberg_table_counts.tsv")"
status_line "$RUN_DIR/p15v2_status.tsv" "port_binding_fail_count	$(awk -F '\t' '$4=="FAIL" {c++} END {print c+0}' "$RUN_DIR/port_binding_scan.tsv")"
status_line "$RUN_DIR/p15v2_status.tsv" "yarn_running_apps_after	$yarn_after"
status_line "$RUN_DIR/p15v2_status.tsv" "p15v2_remote_status	$p15v2_status"
status_line "$RUN_DIR/p15v2_status.tsv" "p15v2_status	$p15v2_status"

cat > "$RUN_DIR/p15v2_summary.md" <<MD
# P15v2 Modular Restart Readiness Summary

- Run name: \`$RUN_NAME\`
- Run dir: \`$RUN_DIR\`
- Base platform status: \`$base_status\`
- P11v2 realtime module status: \`$p11_status\`
- P12v2 query/search module status: \`$p12_status\`
- Governance module status: \`$governance_status\`
- Monitoring module status: \`$monitoring_status\`
- Backup components status: \`$backup_status\`
- Postcheck status: \`$post_status\`
- Status: \`$p15v2_status\`

## Boundary

P15v2 validates modular restart readiness. It does not rebuild business data,
does not rerun P11v2/P12v2, does not regenerate P13v2, does not start Doris,
does not enable Ranger UserSync, does not add Atlas hooks, does not add
Prometheus exporters, and does not use OpenSearch as a mainline component.
No password values are written to this run directory.
MD

step "summary" "$p15v2_status" "$RUN_DIR/p15v2_summary.md"

echo "P15V2_REMOTE_RUN_DIR=$RUN_DIR"
echo "P15V2_REMOTE_STATUS=$p15v2_status"
cat "$RUN_DIR/p15v2_status.tsv"

if [ "$p15v2_status" != "PASS" ]; then
  exit 2
fi

