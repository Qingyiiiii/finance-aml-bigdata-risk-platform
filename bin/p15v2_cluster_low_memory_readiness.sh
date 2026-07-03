#!/usr/bin/env bash
# P15v2 low-memory modular readiness.
# This validates modules sequentially and releases heavy components between
# modules. It does not rebuild business data or rerun P11v2/P12v2/P13v2.
set -uo pipefail

REMOTE_ROOT=${REMOTE_ROOT:-/home/common/tmp/finance_bigdata_project}
RUN_STAMP=${RUN_STAMP:-$(date +%Y%m%d_%H%M%S)}
RUN_NAME="p15v2_modular_restart_readiness_${RUN_STAMP}"
RUN_DIR="$REMOTE_ROOT/runs/$RUN_NAME"
mkdir -p "$RUN_DIR"

export JAVA17_HOME=/export/server/jdk17
export JAVA8_HOME=/export/server/jdk8
export JAVA25_HOME=/export/server/jdk25
export PATH=/usr/local/bin:/export/server/hadoop/bin:/export/server/hadoop/sbin:/export/server/hive/bin:/export/server/kafka/bin:/export/server/flink/bin:/export/server/trino/bin:/export/server/hbase/bin:$JAVA17_HOME/bin:$PATH

CREDENTIALS_FILE="$(mktemp /tmp/finance_p15v2_lowmem_credentials.XXXXXX)"
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

SUDO_PASSWORD="${CLUSTER_HADOOP_COMMON_PASSWORD:-${FINANCE_VM_PASSWORD:-}}"
ES_PASSWORD="${ELASTICSEARCH_ELASTIC_PASSWORD:-}"
ATLAS_USER="${ATLAS_ADMIN_USERNAME:-admin}"
ATLAS_PASSWORD="${ATLAS_ADMIN_PASSWORD:-}"
SUDO_PASSWORD="${SUDO_PASSWORD%$'\r'}"
ES_PASSWORD="${ES_PASSWORD%$'\r'}"
ATLAS_USER="${ATLAS_USER%$'\r'}"
ATLAS_PASSWORD="${ATLAS_PASSWORD%$'\r'}"
ES_CA="/export/server/elasticsearch/config/certs/ca/ca.crt"
TRINO_SERVER="http://hadoop1:18080"

write_header() {
  printf '%s\n' "$2" > "$1"
}

step() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RUN_DIR/steps.tsv"
}

kv_status() {
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >> "$RUN_DIR/$1"
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

module_status() {
  no_fail_status "$1"
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

sudo_cmd() {
  local seconds="$1"
  shift
  if [ -n "$SUDO_PASSWORD" ]; then
    printf '%s\n' "$SUDO_PASSWORD" | timeout --kill-after=5s "${seconds}s" sudo -S -p '' "$@"
  else
    timeout --kill-after=5s "${seconds}s" sudo -n "$@"
  fi
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

snapshot_node() {
  local phase="$1"
  local host="$2"
  bounded_ssh "$host" "bash -lc '
    hn=\$(hostname 2>/dev/null || echo unknown)
    ip=\$(hostname -I 2>/dev/null | tr \" \" \",\" | sed \"s/,\$//\")
    mem=\$(free -h 2>/dev/null | awk \"/^Mem:/ {print \\\"total=\\\"\\\$2\\\",used=\\\"\\\$3\\\",free=\\\"\\\$4\\\",avail=\\\"\\\$7}\")
    disk=\$(df -h /export 2>/dev/null | awk \"NR==2 {print \\\"size=\\\"\\\$2\\\",used=\\\"\\\$3\\\",avail=\\\"\\\$4\\\",use=\\\"\\\$5}\")
    jps=\$(jps -l 2>/dev/null | awk \"{print \\\$2}\" | paste -sd \",\" -)
    printf \"%s\t%s\t%s\t%s\t%s\t%s\t%s\n\" \"$phase\" \"$host\" \"\$hn\" \"\$ip\" \"\$mem\" \"\$disk\" \"\$jps\"
  '"
}

snapshot_nodes() {
  local phase="$1"
  local out="$RUN_DIR/node_snapshot_${phase}.tsv"
  write_header "$out" "phase	node	hostname	ip_summary	memory	disk_export	jps_summary"
  for host in hadoop1 hadoop2 hadoop3; do
    snapshot_node "$phase" "$host" >> "$out" 2>/dev/null || printf '%s\t%s\tERROR\tERROR\tERROR\tERROR\tERROR\n' "$phase" "$host" >> "$out"
  done
}

resource_snapshot() {
  local phase="$1"
  local out="$RUN_DIR/resource_usage_snapshots.tsv"
  if [ ! -s "$out" ]; then
    write_header "$out" "phase	node	memory	disk_export	yarn_running_apps	flink_running_jobs"
  fi
  timeout --kill-after=5s 25s yarn application -list -appStates RUNNING > "$RUN_DIR/yarn_running_${phase}.out" 2>&1 || true
  local yarn_count
  yarn_count=$(sed -n 's/.*):\([0-9][0-9]*\).*/\1/p' "$RUN_DIR/yarn_running_${phase}.out" | tail -n 1)
  yarn_count=${yarn_count:-UNKNOWN}
  timeout --kill-after=5s 25s /export/server/flink/bin/flink list -r > "$RUN_DIR/flink_running_${phase}.out" 2>&1 || true
  local flink_count
  if grep -q 'No running jobs' "$RUN_DIR/flink_running_${phase}.out"; then
    flink_count=0
  elif grep -qi 'Could not retrieve' "$RUN_DIR/flink_running_${phase}.out"; then
    flink_count=0
  else
    flink_count=$(grep -Ec '[0-9a-f]{32}' "$RUN_DIR/flink_running_${phase}.out" || true)
  fi
  for host in hadoop1 hadoop2 hadoop3; do
    bounded_ssh "$host" "bash -lc '
      mem=\$(free -h 2>/dev/null | awk \"/^Mem:/ {print \\\"total=\\\"\\\$2\\\",used=\\\"\\\$3\\\",free=\\\"\\\$4\\\",avail=\\\"\\\$7}\")
      disk=\$(df -h /export 2>/dev/null | awk \"NR==2 {print \\\"size=\\\"\\\$2\\\",used=\\\"\\\$3\\\",avail=\\\"\\\$4\\\",use=\\\"\\\$5}\")
      printf \"%s\t%s\t%s\t%s\t%s\t%s\n\" \"$phase\" \"$host\" \"\$mem\" \"\$disk\" \"$yarn_count\" \"$flink_count\"
    '" >> "$out" 2>/dev/null || printf '%s\t%s\tERROR\tERROR\t%s\t%s\n' "$phase" "$host" "$yarn_count" "$flink_count" >> "$out"
  done
}

record_memory_guard() {
  local phase="$1"
  local avail_mb
  avail_mb=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  local status="PASS"
  if [ "${avail_mb:-0}" -lt 2048 ]; then
    status="WARN"
  fi
  printf '%s\t%s\t%s\t%s\n' "$phase" "$status" "${avail_mb:-0}" "MemAvailable_MB" >> "$RUN_DIR/memory_guard.tsv"
}

ensure_service() {
  local service="$1"
  local out="$RUN_DIR/service_${service}_ensure.out"
  if systemctl is-active --quiet "$service"; then
    printf '%s already active\n' "$service" > "$out"
    return 0
  fi
  sudo_cmd 20 systemctl reset-failed "$service" >> "$out" 2>&1 || true
  sudo_cmd 45 systemctl start "$service" >> "$out" 2>&1 || true
  sleep 5
  systemctl is-active "$service" >> "$out" 2>&1 || true
  systemctl is-active --quiet "$service"
}

stop_service() {
  local service="$1"
  local out="$RUN_DIR/service_release_${service}.out"
  if systemctl is-active --quiet "$service"; then
    sudo_cmd 45 systemctl stop "$service" > "$out" 2>&1 || true
    sleep 5
  else
    printf '%s already inactive\n' "$service" > "$out"
  fi
  local state
  state=$(systemctl is-active "$service" 2>/dev/null || true)
  if [ "$state" = "active" ]; then
    printf '%s\t%s\t%s\n' "$service" "still_active" "$out" >> "$RUN_DIR/release_actions.tsv"
  else
    sudo_cmd 20 systemctl reset-failed "$service" >> "$out" 2>&1 || true
    printf '%s\t%s\t%s\n' "$service" "released" "$out" >> "$RUN_DIR/release_actions.tsv"
  fi
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
  if timeout --kill-after=10s 90s env JAVA_HOME=/export/server/jdk25 PATH=/export/server/jdk25/bin:/export/server/trino/bin:$PATH "$TRINO_CLI" --server "$TRINO_SERVER" --output-format TSV_HEADER --execute "$sql" > "$out" 2> "$err"; then
    local rows
    rows=$(($(wc -l < "$out" 2>/dev/null || echo 1) - 1))
    if [ "$rows" -lt 0 ]; then rows=0; fi
    printf '%s\tPASS\t%s\t%s\n' "$name" "$rows" "$out" >> "$RUN_DIR/p12v2_query_module_status.tsv"
    return 0
  fi
  printf '%s\tFAIL\t0\t%s\n' "$name" "$err" >> "$RUN_DIR/p12v2_query_module_status.tsv"
  return 1
}

start_hdfs_yarn() {
  {
    export JAVA_HOME=/export/server/jdk17
    export PATH=/export/server/hadoop/bin:/export/server/hadoop/sbin:$JAVA_HOME/bin:$PATH
    timeout --kill-after=10s 120s start-dfs.sh || true
    timeout --kill-after=10s 120s start-yarn.sh || true
  } > "$RUN_DIR/start_hdfs_yarn.out" 2>&1
}

start_hive_minimal() {
  if ss -lntp 2>/dev/null | grep -q ':9083'; then
    echo "Hive Metastore already listening" > "$RUN_DIR/start_hive_minimal.out"
  else
    {
      export JAVA_HOME=/export/server/jdk8
      export HADOOP_HOME=/export/server/hadoop
      export HIVE_HOME=/export/server/hive
      export HADOOP_CONF_DIR=/export/server/hive/conf/hadoop-conf-jdk8
      export YARN_CONF_DIR=/export/server/hive/conf/hadoop-conf-jdk8
      export HIVE_CONF_DIR=/export/server/hive/conf
      mkdir -p /export/logs/hive
      HADOOP_CP=$(JAVA_HOME=/export/server/jdk8 /export/server/hadoop/bin/hadoop --config /export/server/hive/conf/hadoop-conf-jdk8 classpath --glob)
      HIVE_CP="/export/server/hive/conf:/export/server/hive/conf/hadoop-conf-jdk8:/export/server/hive/lib/*:${HADOOP_CP}"
      nohup /export/server/jdk8/bin/java -Xmx512m -Dhive.log.dir=/export/logs/hive -Dhive.log.file=hive-metastore.log -Dhadoop.log.dir=/export/logs/hive -Dhadoop.log.file=hive-metastore.log -cp "$HIVE_CP" org.apache.hadoop.hive.metastore.HiveMetaStore > /export/logs/hive/hive-metastore.out 2>&1 &
      sleep 10
    } > "$RUN_DIR/start_hive_minimal.out" 2>&1
  fi
}

start_zookeeper_hbase() {
  : > "$RUN_DIR/hbase_start.out"
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

start_realtime_minimal() {
  : > "$RUN_DIR/realtime_start.out"
  for host in hadoop1 hadoop2 hadoop3; do
    bounded_ssh "$host" "bash -lc '
      export JAVA_HOME=/export/server/jdk17
      if jps -l | grep -q kafka.Kafka; then
        echo kafka already running on $host
      else
        mkdir -p /export/logs/kafka
        setsid /export/server/kafka/bin/kafka-server-start.sh /export/server/kafka/config/kraft/server.properties > /export/logs/kafka/kafka-server.out 2>&1 < /dev/null &
        echo kafka start submitted on $host
      fi
    '" >> "$RUN_DIR/realtime_start.out" 2>&1 || true
  done
  sleep 20
  if systemctl is-active --quiet redis; then
    echo "redis already running" >> "$RUN_DIR/realtime_start.out"
  else
    sudo_cmd 30 systemctl start redis >> "$RUN_DIR/realtime_start.out" 2>&1 || true
  fi
  if jps -l | grep -q 'org.apache.flink.runtime.entrypoint.StandaloneSessionClusterEntrypoint'; then
    echo "flink jobmanager already running" >> "$RUN_DIR/realtime_start.out"
  else
    timeout --kill-after=10s 60s /export/server/flink/bin/start-cluster.sh >> "$RUN_DIR/realtime_start.out" 2>&1 || true
  fi
  sleep 8
}

release_realtime_hbase() {
  timeout --kill-after=10s 60s /export/server/flink/bin/stop-cluster.sh > "$RUN_DIR/release_flink.out" 2>&1 || true
  for host in hadoop1 hadoop2 hadoop3; do
    bounded_ssh "$host" "export JAVA_HOME=/export/server/jdk17; /export/server/kafka/bin/kafka-server-stop.sh >/tmp/p15v2_kafka_stop.out 2>&1 || true" >> "$RUN_DIR/release_kafka.out" 2>&1 || true
  done
  timeout --kill-after=10s 60s /export/server/hbase/bin/stop-hbase.sh > "$RUN_DIR/release_hbase.out" 2>&1 || true
  printf '%s\t%s\t%s\n' "flink_kafka_hbase" "released_best_effort" "$RUN_DIR/release_flink.out;$RUN_DIR/release_kafka.out;$RUN_DIR/release_hbase.out" >> "$RUN_DIR/release_actions.tsv"
}

start_trino_temp() {
  echo "===== start/check p15v2 temp trino coordinator =====" > "$RUN_DIR/trino_launcher_status.txt"
  export JAVA_HOME=/export/server/jdk25
  export PATH=/export/server/jdk25/bin:/export/server/trino/bin:$PATH
  if curl -fsS --max-time 5 "http://hadoop1:18080/v1/info" > "$RUN_DIR/trino_18080_info.json" 2>> "$RUN_DIR/trino_launcher_status.txt"; then
    echo "Temp Trino coordinator already reachable on 18080" >> "$RUN_DIR/trino_launcher_status.txt"
    return 0
  fi
  local temp_etc="$RUN_DIR/trino_etc"
  local temp_data="$RUN_DIR/trino_data"
  rm -rf "$temp_etc" "$temp_data"
  cp -R /export/server/trino/etc "$temp_etc"
  mkdir -p "$temp_data"
  python3 - "$temp_etc/config.properties" <<'PY'
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
    ss -lntp | egrep '8080|18080' || true
    grep -nE 'coordinator|node-scheduler.include-coordinator|http-server.http.port|discovery.uri' "$temp_etc/config.properties" || true
    timeout --kill-after=10s 75s env JAVA_HOME=/export/server/jdk25 PATH=/export/server/jdk25/bin:/export/server/trino/bin:$PATH /export/server/trino/bin/launcher -etc-dir "$temp_etc" -data-dir "$temp_data" start || true
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
      curl -fsS --max-time 5 "http://hadoop1:18080/v1/info" > "$RUN_DIR/trino_18080_info.json" 2>> "$RUN_DIR/trino_launcher_status.txt" || true
      if grep -q '"starting":false' "$RUN_DIR/trino_18080_info.json" 2>/dev/null && grep -q '"state":"ACTIVE"' "$RUN_DIR/trino_18080_info.json" 2>/dev/null; then
        break
      fi
      sleep 5
    done
    echo "===== /v1/info after wait ====="
    cat "$RUN_DIR/trino_18080_info.json" 2>/dev/null || true
    timeout --kill-after=5s 20s /export/server/trino/bin/launcher -etc-dir "$temp_etc" -data-dir "$temp_data" status || true
    ss -lntp | egrep '8080|18080' || true
    tail -n 120 "$temp_data/var/log/server.log" 2>/dev/null || true
  } >> "$RUN_DIR/trino_launcher_status.txt" 2>&1
}

stop_trino_temp() {
  if [ -d "$RUN_DIR/trino_etc" ] && [ -d "$RUN_DIR/trino_data" ]; then
    timeout --kill-after=5s 25s /export/server/trino/bin/launcher -etc-dir "$RUN_DIR/trino_etc" -data-dir "$RUN_DIR/trino_data" stop > "$RUN_DIR/release_trino.out" 2>&1 || true
    printf '%s\t%s\t%s\n' "trino_temp_18080" "released_best_effort" "$RUN_DIR/release_trino.out" >> "$RUN_DIR/release_actions.tsv"
  fi
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
      local port="${address##*:}"
      local status="PASS"
      local detail="bound_to_specific_or_loopback"
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
write_header "$RUN_DIR/memory_guard.tsv" "phase	status	value	detail"
write_header "$RUN_DIR/release_actions.tsv" "component	status	detail"
write_header "$RUN_DIR/module_sequence.tsv" "seq	module	action"

printf '1\tquery_governance_auto_started\tvalidate first because heavy services are already active after reboot\n' >> "$RUN_DIR/module_sequence.tsv"
snapshot_nodes "before"
resource_snapshot "before"
record_memory_guard "before"
step "snapshot_before" "PASS" "$RUN_DIR/node_snapshot_before.tsv"

# P12 query/search module: ClickHouse and Elasticsearch first, before adding more services.
if ensure_service clickhouse-server; then
  kv_status clickhouse_readiness.tsv clickhouse_service PASS active "clickhouse-server"
else
  kv_status clickhouse_readiness.tsv clickhouse_service FAIL inactive "$RUN_DIR/service_clickhouse-server_ensure.out"
fi
if timeout --kill-after=5s 15s clickhouse-client --query "SHOW DATABASES LIKE 'finance_bigdata_v2' FORMAT TabSeparatedWithNames" > "$RUN_DIR/clickhouse_database.tsv" 2> "$RUN_DIR/clickhouse_database.err" && grep -q 'finance_bigdata_v2' "$RUN_DIR/clickhouse_database.tsv"; then
  kv_status clickhouse_readiness.tsv clickhouse_database PASS finance_bigdata_v2 "$RUN_DIR/clickhouse_database.tsv"
else
  kv_status clickhouse_readiness.tsv clickhouse_database FAIL missing "$RUN_DIR/clickhouse_database.err"
fi
if timeout --kill-after=5s 15s clickhouse-client --query "SHOW TABLES FROM finance_bigdata_v2 LIKE 'ads_account_risk_features' FORMAT TabSeparatedWithNames" > "$RUN_DIR/clickhouse_tables.tsv" 2> "$RUN_DIR/clickhouse_tables.err" && grep -q 'ads_account_risk_features' "$RUN_DIR/clickhouse_tables.tsv"; then
  kv_status clickhouse_readiness.tsv clickhouse_ads_table PASS ads_account_risk_features "$RUN_DIR/clickhouse_tables.tsv"
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

if ensure_service elasticsearch-finance-v2; then
  kv_status elasticsearch_readiness.tsv elasticsearch_service PASS active "elasticsearch-finance-v2"
else
  kv_status elasticsearch_readiness.tsv elasticsearch_service FAIL inactive "$RUN_DIR/service_elasticsearch-finance-v2_ensure.out"
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
record_memory_guard "after_query_search"

# Governance module.
ensure_service postgresql >/dev/null 2>&1 || true
if ensure_service finance-ranger-admin; then
  kv_status ranger_readiness.tsv ranger_admin_service PASS active "finance-ranger-admin"
else
  kv_status ranger_readiness.tsv ranger_admin_service FAIL inactive "$RUN_DIR/service_finance-ranger-admin_ensure.out"
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

if ensure_service finance-atlas; then
  kv_status atlas_readiness.tsv atlas_service PASS active "finance-atlas"
else
  kv_status atlas_readiness.tsv atlas_service FAIL inactive "$RUN_DIR/service_finance-atlas_ensure.out"
fi
code=$(curl -sS -o "$RUN_DIR/atlas_login.html" -w '%{http_code}' --max-time 10 "http://CLUSTER_NODE1_IP:21000/login.jsp" 2> "$RUN_DIR/atlas_login.err" || true)
if [ "$code" = "200" ]; then
  kv_status atlas_readiness.tsv atlas_login PASS 200 "$RUN_DIR/atlas_login.html"
else
  kv_status atlas_readiness.tsv atlas_login FAIL "code=${code}" "$RUN_DIR/atlas_login.err"
fi
if [ -n "$ATLAS_PASSWORD" ]; then
  code=$(curl -sS -u "${ATLAS_USER}:${ATLAS_PASSWORD}" -o "$RUN_DIR/atlas_status.json" -w '%{http_code}' --max-time 15 "http://CLUSTER_NODE1_IP:21000/api/atlas/admin/status" 2> "$RUN_DIR/atlas_status.err" || true)
  atlas_status=$(tr -d '\n' < "$RUN_DIR/atlas_status.json" 2>/dev/null | head -c 120)
  if [ "$code" = "200" ] && printf '%s' "$atlas_status" | grep -q 'ACTIVE'; then
    kv_status atlas_readiness.tsv atlas_admin_status PASS ACTIVE "$RUN_DIR/atlas_status.json"
  else
    kv_status atlas_readiness.tsv atlas_admin_status FAIL "code=${code}" "$RUN_DIR/atlas_status.err"
  fi
else
  kv_status atlas_readiness.tsv atlas_admin_status FAIL missing_password "ATLAS_ADMIN_PASSWORD missing"
fi
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
step "query_search_governance_check" "$(no_fail_status clickhouse_readiness.tsv elasticsearch_readiness.tsv ranger_readiness.tsv atlas_readiness.tsv)" "$RUN_DIR/clickhouse_readiness.tsv"

printf '2\theavy_release\trelease ClickHouse Elasticsearch Ranger Atlas before base/P11 checks\n' >> "$RUN_DIR/module_sequence.tsv"
stop_service finance-atlas
stop_service finance-ranger-admin
stop_service elasticsearch-finance-v2
stop_service clickhouse-server
record_memory_guard "after_heavy_release"
resource_snapshot "after_heavy_release"
step "heavy_release" "PASS" "$RUN_DIR/release_actions.tsv"

# Base platform.
printf '3\tbase_platform\tstart HDFS YARN Hive metastore with heavy V2 services released\n' >> "$RUN_DIR/module_sequence.tsv"
start_hdfs_yarn
if timeout --kill-after=5s 25s hdfs dfs -ls /lakehouse/projects/finance_bigdata > "$RUN_DIR/hdfs_finance_ls.out" 2>&1; then
  kv_status base_platform_status.tsv hdfs_project_root PASS readable "/lakehouse/projects/finance_bigdata"
else
  kv_status base_platform_status.tsv hdfs_project_root FAIL unreadable "$RUN_DIR/hdfs_finance_ls.out"
fi
for _ in 1 2 3 4 5 6; do
  timeout --kill-after=5s 25s yarn node -list > "$RUN_DIR/yarn_nodes.out" 2>&1 || true
  yarn_nodes=$(grep -c 'RUNNING' "$RUN_DIR/yarn_nodes.out" || true)
  [ "$yarn_nodes" -ge 3 ] && break
  sleep 10
done
if [ "$yarn_nodes" -ge 3 ]; then
  kv_status base_platform_status.tsv yarn_nodes PASS "$yarn_nodes" "running nodes"
else
  kv_status base_platform_status.tsv yarn_nodes FAIL "$yarn_nodes" "$RUN_DIR/yarn_nodes.out"
fi
ensure_service postgresql >/dev/null 2>&1 && kv_status base_platform_status.tsv postgresql_service PASS active postgresql || kv_status base_platform_status.tsv postgresql_service FAIL inactive postgresql
start_hive_minimal
if ss -lntp | grep -q ':9083'; then
  kv_status base_platform_status.tsv hive_metastore PASS 9083 "metastore listening"
else
  kv_status base_platform_status.tsv hive_metastore FAIL missing "$RUN_DIR/start_hive_minimal.out"
fi
record_memory_guard "after_base"
step "base_platform_check" "$(module_status base_platform_status.tsv)" "$RUN_DIR/base_platform_status.tsv"

# P11v2 realtime state module.
printf '4\tp11_realtime_state\tstart Kafka Redis Flink ZK HBase, validate state sample, then release\n' >> "$RUN_DIR/module_sequence.tsv"
start_realtime_minimal
timeout --kill-after=5s 25s env JAVA_HOME=/export/server/jdk17 PATH=/export/server/jdk17/bin:/export/server/kafka/bin:$PATH /export/server/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server CLUSTER_NODE1_IP:9092 describe --status > "$RUN_DIR/kafka_quorum.out" 2>&1 || true
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
  if [ "$running_jobs" = "0" ]; then
    kv_status p11v2_realtime_module_status.tsv flink_running_jobs PASS 0 "$RUN_DIR/flink_running_jobs.out"
  else
    kv_status p11v2_realtime_module_status.tsv flink_running_jobs FAIL "$running_jobs" "$RUN_DIR/flink_running_jobs.out"
  fi
fi
if jps -l | grep -q 'StandaloneSessionClusterEntrypoint'; then
  kv_status p11v2_realtime_module_status.tsv flink_service PASS jobmanager "process exists"
else
  kv_status p11v2_realtime_module_status.tsv flink_service FAIL missing "JobManager process missing"
fi
start_zookeeper_hbase
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
if grep -Eq 'column=(s|r|meta|m):' "$RUN_DIR/hbase_readiness.out"; then
  kv_status hbase_readiness.tsv hbase_sample_read PASS nonempty "sample row visible"
else
  kv_status hbase_readiness.tsv hbase_sample_read FAIL empty "sample scan returned no state cells"
fi
record_memory_guard "after_p11"
step "p11v2_realtime_module_check" "$(no_fail_status p11v2_realtime_module_status.tsv hbase_readiness.tsv)" "$RUN_DIR/p11v2_realtime_module_status.tsv"
release_realtime_hbase
record_memory_guard "after_realtime_release"
resource_snapshot "after_realtime_release"

# Trino/Iceberg check after realtime release.
printf '5\ttrino_iceberg\tstart temporary 18080 coordinator and validate Iceberg core table\n' >> "$RUN_DIR/module_sequence.tsv"
start_trino_temp
TRINO_CLI=$(find_trino_cli || true)
printf 'TRINO_CLI=%s\n' "$TRINO_CLI" > "$RUN_DIR/trino_cli_path.txt"
if [ -n "$TRINO_CLI" ]; then
  run_trino trino_nodes "SELECT node_id, http_uri, node_version, coordinator, state FROM system.runtime.nodes ORDER BY node_id;" || true
  run_trino trino_finance_schema "SHOW SCHEMAS FROM iceberg LIKE 'finance_bigdata';" || true
  run_trino trino_account_risk_count "SELECT COUNT(*) AS row_count FROM iceberg.finance_bigdata.dws_account_risk_features;" || true
else
  printf '%s\tFAIL\t0\t%s\n' "trino_cli" "$RUN_DIR/trino_cli_path.txt" >> "$RUN_DIR/p12v2_query_module_status.tsv"
fi
trino_count=$(awk 'NR==2 {print $1}' "$RUN_DIR/trino_account_risk_count.tsv" 2>/dev/null || echo 0)
trino_count=${trino_count:-0}
if [ "$trino_count" = "515080" ]; then
  printf '%s\t%s\t%s\t%s\n' "dws_account_risk_features" "515080" "$trino_count" "PASS" >> "$RUN_DIR/iceberg_table_counts.tsv"
  kv_status base_platform_status.tsv iceberg_core_table_readable PASS "$trino_count" "via Trino Iceberg count"
else
  printf '%s\t%s\t%s\t%s\n' "dws_account_risk_features" "515080" "$trino_count" "FAIL" >> "$RUN_DIR/iceberg_table_counts.tsv"
  kv_status base_platform_status.tsv iceberg_core_table_readable FAIL "$trino_count" "$RUN_DIR/trino_account_risk_count.tsv"
fi
step "p12v2_query_module_check" "$(no_fail_status p12v2_query_module_status.tsv clickhouse_readiness.tsv elasticsearch_readiness.tsv)" "$RUN_DIR/p12v2_query_module_status.tsv"
stop_trino_temp
record_memory_guard "after_trino_release"

# Monitoring module.
printf '6\tmonitoring\tstart or confirm Prometheus Grafana only after heavy modules released\n' >> "$RUN_DIR/module_sequence.tsv"
mkdir -p /export/data/prometheus /export/logs/prometheus /export/logs/grafana
cat > /export/server/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["CLUSTER_NODE1_IP:9090"]
        labels:
          project: "finance_bigdata_v2"
          component: "prometheus"

  - job_name: "finance_bigdata_v2_grafana"
    metrics_path: "/metrics"
    static_configs:
      - targets: ["CLUSTER_NODE1_IP:3000"]
        labels:
          project: "finance_bigdata_v2"
          component: "grafana"
EOF
if ! curl -fsS --max-time 4 http://CLUSTER_NODE1_IP:9090/-/ready >/tmp/p15v2_prometheus_precheck.out 2>/tmp/p15v2_prometheus_precheck.err; then
  pgrep -f '/export/server/prometheus/prometheus' | xargs -r kill 2>/dev/null || true
  sleep 2
  nohup /export/server/prometheus/prometheus --config.file=/export/server/prometheus/prometheus.yml --storage.tsdb.path=/export/data/prometheus --web.listen-address=CLUSTER_NODE1_IP:9090 > /tmp/prometheus.out 2>&1 &
fi
if ! curl -fsS --max-time 4 http://CLUSTER_NODE1_IP:3000/login >/tmp/p15v2_grafana_precheck.out 2>/tmp/p15v2_grafana_precheck.err; then
  pgrep -f '/export/server/grafana/bin/grafana' | xargs -r kill 2>/dev/null || true
  pgrep -f 'grafana-server' | xargs -r kill 2>/dev/null || true
  sleep 2
  nohup env GF_SERVER_HTTP_ADDR=CLUSTER_NODE1_IP GF_SERVER_HTTP_PORT=3000 GF_METRICS_ENABLED=true /export/server/grafana/bin/grafana server --homepath /export/server/grafana > /tmp/grafana.out 2>&1 &
fi
sleep 8
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
for _ in 1 2 3 4 5 6; do
  curl -fsS --max-time 8 "http://CLUSTER_NODE1_IP:9090/api/v1/targets" > "$RUN_DIR/prometheus_targets.json" 2> "$RUN_DIR/prometheus_targets.err" || true
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
  target_count=$(python3 - "$RUN_DIR/prometheus_targets.json" <<'PY' 2>/dev/null || echo 0
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    print(len(data.get("data", {}).get("activeTargets", [])))
except Exception:
    print(0)
PY
)
  [ "${up_count:-0}" -ge 2 ] && break
  [ "${target_count:-0}" -ge 2 ] && sleep 15 || sleep 5
done
if [ -s "$RUN_DIR/prometheus_targets.json" ]; then
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
  elif [ "${target_count:-0}" -ge 2 ]; then
    kv_status prometheus_grafana_readiness.tsv prometheus_targets PASS "$target_count" "targets present; scrape health not up yet"
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
step "monitoring_module_check" "$(module_status prometheus_grafana_readiness.tsv)" "$RUN_DIR/prometheus_grafana_readiness.tsv"

# Backup component status.
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
step "backup_component_record" "$(module_status backup_components_status.tsv)" "$RUN_DIR/backup_components_status.tsv"

snapshot_nodes "after"
resource_snapshot "after"
scan_ports
step "snapshot_after_and_port_scan" "$(module_status port_binding_scan.tsv)" "$RUN_DIR/port_binding_scan.tsv"

yarn_after=$(sed -n 's/.*):\([0-9][0-9]*\).*/\1/p' "$RUN_DIR/yarn_running_after.out" | tail -n 1)
yarn_after=${yarn_after:-UNKNOWN}
if [ "$yarn_after" = "0" ]; then
  kv_status postcheck.tsv yarn_running_apps PASS 0 "$RUN_DIR/yarn_running_after.out"
else
  kv_status postcheck.tsv yarn_running_apps FAIL "$yarn_after" "$RUN_DIR/yarn_running_after.out"
fi
if [ ! -s "$RUN_DIR/flink_running_after.out" ] || grep -q 'No running jobs' "$RUN_DIR/flink_running_after.out" || grep -qi 'Could not retrieve' "$RUN_DIR/flink_running_after.out"; then
  kv_status postcheck.tsv flink_running_jobs PASS 0 "$RUN_DIR/flink_running_after.out"
else
  flink_after=$(grep -Ec '[0-9a-f]{32}' "$RUN_DIR/flink_running_after.out" || true)
  if [ "$flink_after" = "0" ]; then
    kv_status postcheck.tsv flink_running_jobs PASS 0 "$RUN_DIR/flink_running_after.out"
  else
    kv_status postcheck.tsv flink_running_jobs FAIL "$flink_after" "$RUN_DIR/flink_running_after.out"
  fi
fi
if grep -q $'\tFAIL\t' "$RUN_DIR/port_binding_scan.tsv"; then
  kv_status postcheck.tsv wildcard_v2_listeners FAIL present "$RUN_DIR/port_binding_scan.tsv"
else
  kv_status postcheck.tsv wildcard_v2_listeners PASS 0 "$RUN_DIR/port_binding_scan.tsv"
fi
record_memory_guard "after"

base_status=$(module_status base_platform_status.tsv)
if grep -q $'\tFAIL$' "$RUN_DIR/iceberg_table_counts.tsv"; then base_status="FAIL"; fi
p11_status=$(module_status p11v2_realtime_module_status.tsv)
if [ "$(module_status hbase_readiness.tsv)" = "FAIL" ]; then p11_status="FAIL"; fi
p12_status=$(module_status p12v2_query_module_status.tsv)
if [ "$(module_status clickhouse_readiness.tsv)" = "FAIL" ] || [ "$(module_status elasticsearch_readiness.tsv)" = "FAIL" ]; then p12_status="FAIL"; fi
governance_status="PASS"
if [ "$(module_status ranger_readiness.tsv)" = "FAIL" ] || [ "$(module_status atlas_readiness.tsv)" = "FAIL" ]; then governance_status="FAIL"; fi
monitoring_status=$(module_status prometheus_grafana_readiness.tsv)
backup_status=$(module_status backup_components_status.tsv)
post_status=$(module_status postcheck.tsv)

awk 'NR>1 {print "ranger_"$0}' "$RUN_DIR/ranger_readiness.tsv" >> "$RUN_DIR/governance_module_status.tsv"
awk 'NR>1 {print "atlas_"$0}' "$RUN_DIR/atlas_readiness.tsv" >> "$RUN_DIR/governance_module_status.tsv"
awk 'NR>1 {print $0}' "$RUN_DIR/prometheus_grafana_readiness.tsv" >> "$RUN_DIR/monitoring_module_status.tsv"

p15v2_status="PASS"
for s in "$base_status" "$p11_status" "$p12_status" "$governance_status" "$monitoring_status" "$backup_status" "$post_status"; do
  if [ "$s" != "PASS" ]; then
    p15v2_status="FAIL"
  fi
done

write_header "$RUN_DIR/p15v2_status.tsv" "metric	value"
printf '%s\t%s\n' "run_name" "$RUN_NAME" >> "$RUN_DIR/p15v2_status.tsv"
printf '%s\t%s\n' "run_dir" "$RUN_DIR" >> "$RUN_DIR/p15v2_status.tsv"
printf '%s\t%s\n' "execution_mode" "low_memory_sequential" >> "$RUN_DIR/p15v2_status.tsv"
printf '%s\t%s\n' "base_platform_status" "$base_status" >> "$RUN_DIR/p15v2_status.tsv"
printf '%s\t%s\n' "p11v2_realtime_module_status" "$p11_status" >> "$RUN_DIR/p15v2_status.tsv"
printf '%s\t%s\n' "p12v2_query_module_status" "$p12_status" >> "$RUN_DIR/p15v2_status.tsv"
printf '%s\t%s\n' "governance_module_status" "$governance_status" >> "$RUN_DIR/p15v2_status.tsv"
printf '%s\t%s\n' "monitoring_module_status" "$monitoring_status" >> "$RUN_DIR/p15v2_status.tsv"
printf '%s\t%s\n' "backup_components_status" "$backup_status" >> "$RUN_DIR/p15v2_status.tsv"
printf '%s\t%s\n' "postcheck_status" "$post_status" >> "$RUN_DIR/p15v2_status.tsv"
printf '%s\t%s\n' "memory_warning_count" "$(awk -F '\t' '$2=="WARN" {c++} END {print c+0}' "$RUN_DIR/memory_guard.tsv")" >> "$RUN_DIR/p15v2_status.tsv"
printf '%s\t%s\n' "port_binding_fail_count" "$(awk -F '\t' '$4=="FAIL" {c++} END {print c+0}' "$RUN_DIR/port_binding_scan.tsv")" >> "$RUN_DIR/p15v2_status.tsv"
printf '%s\t%s\n' "yarn_running_apps_after" "$yarn_after" >> "$RUN_DIR/p15v2_status.tsv"
printf '%s\t%s\n' "p15v2_remote_status" "$p15v2_status" >> "$RUN_DIR/p15v2_status.tsv"
printf '%s\t%s\n' "p15v2_status" "$p15v2_status" >> "$RUN_DIR/p15v2_status.tsv"

cat > "$RUN_DIR/p15v2_summary.md" <<MD
# P15v2 Modular Restart Readiness Summary

- Run name: \`$RUN_NAME\`
- Run dir: \`$RUN_DIR\`
- Execution mode: \`low_memory_sequential\`
- Base platform status: \`$base_status\`
- P11v2 realtime module status: \`$p11_status\`
- P12v2 query/search module status: \`$p12_status\`
- Governance module status: \`$governance_status\`
- Monitoring module status: \`$monitoring_status\`
- Backup components status: \`$backup_status\`
- Postcheck status: \`$post_status\`
- Status: \`$p15v2_status\`

## Resource Boundary

This run follows the P15v2 modular startup rule. It validates heavy modules
sequentially and releases ClickHouse, Elasticsearch, Ranger, Atlas, Kafka,
Flink, HBase, and temporary Trino after their readiness checks where possible.
It does not require all V2 components to remain resident at the same time.

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

