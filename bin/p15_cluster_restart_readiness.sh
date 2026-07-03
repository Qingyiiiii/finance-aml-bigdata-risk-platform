#!/usr/bin/env bash
# Purpose: P15 集群重启恢复检查脚本，验证基础服务、实时服务、Iceberg 表和关键证据状态。
# Boundary: Redis latest-state 可能受重启影响，恢复检查要按脚本定义区分 PASS/WARN/FAIL。
set -uo pipefail

REMOTE_ROOT=${REMOTE_ROOT:-/home/common/tmp/finance_bigdata_project}
RUN_STAMP=$(date +%Y%m%d_%H%M%S)
RUN_NAME="p15_restart_readiness_${RUN_STAMP}"
RUN_DIR="$REMOTE_ROOT/runs/$RUN_NAME"
mkdir -p "$RUN_DIR"

export JAVA_HOME=/export/server/jdk17
export PATH=/export/server/spark/bin:/export/server/hadoop/bin:/export/server/hadoop/sbin:/export/server/kafka/bin:/export/server/flink/bin:$JAVA_HOME/bin:$PATH

SPARK_ARGS=(
  --conf spark.executor.instances=1
  --conf spark.executor.cores=1
  --conf spark.executor.memory=512m
  --conf spark.executor.memoryOverhead=256m
  --conf spark.driver.memory=512m
  --conf spark.driver.bindAddress=0.0.0.0
  --conf spark.driver.host=hadoop1
  --conf spark.driver.port=37201
  --conf spark.blockManager.port=37202
  --conf spark.sql.shuffle.partitions=2
)

TABLES=(
  "dwd_finance_transactions:5078345"
  "dwd_finance_accounts:518581"
  "dwd_finance_transaction_events:10156690"
  "dws_minute_transaction_kpi:88316"
  "dws_account_risk_features:515080"
  "dws_payment_format_kpi:7"
  "dws_large_transaction_candidates:200403"
)

P6_REDIS_PATTERN="finance_bigdata:risk:latest:*"
P11_REDIS_PATTERN="finance_bigdata:p11:risk:latest:*"

echo -e "component\tstatus\tdetail" > "$RUN_DIR/component_status.tsv"
echo -e "table_name\texpected_count\tactual_count\tstatus" > "$RUN_DIR/table_counts.tsv"
echo -e "metric\tvalue\tstatus\tdetail" > "$RUN_DIR/realtime_restart_status.tsv"
echo -e "step\tstatus\tdetail" > "$RUN_DIR/steps.tsv"

component() {
  echo -e "$1\t$2\t$3" >> "$RUN_DIR/component_status.tsv"
}

metric() {
  echo -e "$1\t$2\t$3\t$4" >> "$RUN_DIR/realtime_restart_status.tsv"
}

step() {
  echo -e "$1\t$2\t$3" >> "$RUN_DIR/steps.tsv"
}

for host in hadoop1 hadoop2 hadoop3; do
  {
    echo "===== $host ====="
    ssh -n common@"$host" "hostname; jps -l; free -h; df -h /export"
  } >> "$RUN_DIR/node_snapshot.txt" 2>&1
done
step "node_snapshot" "PASS" "$RUN_DIR/node_snapshot.txt"

if timeout 20s hdfs dfs -ls /lakehouse/projects/finance_bigdata > "$RUN_DIR/hdfs_finance_ls.out" 2>&1; then
  component "hdfs" "PASS" "/lakehouse/projects/finance_bigdata readable"
else
  component "hdfs" "FAIL" "$RUN_DIR/hdfs_finance_ls.out"
fi

if timeout 20s yarn node -list > "$RUN_DIR/yarn_nodes.out" 2>&1; then
  running_nodes=$(grep -c 'RUNNING' "$RUN_DIR/yarn_nodes.out" || true)
  if [[ "$running_nodes" -ge 3 ]]; then
    component "yarn_nodes" "PASS" "running_nodes=$running_nodes"
  else
    component "yarn_nodes" "FAIL" "running_nodes=$running_nodes"
  fi
else
  component "yarn_nodes" "FAIL" "$RUN_DIR/yarn_nodes.out"
fi

timeout 20s yarn application -list -appStates RUNNING > "$RUN_DIR/yarn_running_apps.out" 2>&1 || true
if grep -q 'Total number of applications.*:0' "$RUN_DIR/yarn_running_apps.out"; then
  component "yarn_running_apps" "PASS" "running_applications=0"
else
  component "yarn_running_apps" "FAIL" "$RUN_DIR/yarn_running_apps.out"
fi

if timeout 45s /export/server/hive/bin/beeline -u "jdbc:hive2://hadoop1:10000/default" -n common -e "SHOW DATABASES LIKE 'finance_bigdata';" > "$RUN_DIR/beeline_finance_database.out" 2>&1 && grep -q 'finance_bigdata' "$RUN_DIR/beeline_finance_database.out"; then
  component "hive" "PASS" "finance_bigdata visible via beeline"
else
  component "hive" "FAIL" "$RUN_DIR/beeline_finance_database.out"
fi

if /export/server/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server CLUSTER_NODE1_IP:9092 describe --status > "$RUN_DIR/kafka_quorum.out" 2>&1 && grep -q 'CurrentVoters' "$RUN_DIR/kafka_quorum.out"; then
  component "kafka" "PASS" "quorum status returned"
else
  component "kafka" "FAIL" "$RUN_DIR/kafka_quorum.out"
fi

if [[ "$(redis-cli -h 127.0.0.1 ping 2>/dev/null)" == "PONG" ]]; then
  component "redis" "PASS" "PING=PONG"
else
  component "redis" "FAIL" "PING failed"
fi

/export/server/flink/bin/flink list -r > "$RUN_DIR/flink_running_jobs.out" 2>&1 || true
if grep -q 'No running jobs' "$RUN_DIR/flink_running_jobs.out"; then
  component "flink_running_jobs" "PASS" "No running jobs"
else
  component "flink_running_jobs" "FAIL" "$RUN_DIR/flink_running_jobs.out"
fi
if jps -l | grep -q 'StandaloneSessionClusterEntrypoint'; then
  component "flink_service" "PASS" "JobManager process exists"
else
  component "flink_service" "FAIL" "JobManager process missing"
fi

spark-sql "${SPARK_ARGS[@]}" -e "SHOW TABLES IN lakehouse.finance_bigdata;" > "$RUN_DIR/spark_show_tables.out" 2>&1
if grep -q 'dwd_finance_transactions' "$RUN_DIR/spark_show_tables.out"; then
  component "iceberg_namespace" "PASS" "lakehouse.finance_bigdata visible"
else
  component "iceberg_namespace" "FAIL" "$RUN_DIR/spark_show_tables.out"
fi

run_count() {
  local table_name="$1"
  spark-sql "${SPARK_ARGS[@]}" -S -e "SELECT COUNT(*) FROM lakehouse.finance_bigdata.${table_name};" 2>/dev/null | awk '/^[0-9]+$/ {v=$1} END {print v}'
}

for pair in "${TABLES[@]}"; do
  table_name="${pair%%:*}"
  expected_count="${pair##*:}"
  actual_count="$(run_count "$table_name")"
  if [[ "$actual_count" == "$expected_count" ]]; then
    status="PASS"
  else
    status="FAIL"
  fi
  echo -e "${table_name}\t${expected_count}\t${actual_count}\t${status}" >> "$RUN_DIR/table_counts.tsv"
done
step "iceberg_table_counts" "PASS" "$RUN_DIR/table_counts.tsv"

/export/server/kafka/bin/kafka-topics.sh --bootstrap-server CLUSTER_NODE1_IP:9092 --list > "$RUN_DIR/kafka_topics.out" 2>&1 || true
finance_topic_count=$(grep -c '^finance' "$RUN_DIR/kafka_topics.out" || true)
if [[ "$finance_topic_count" -gt 0 ]]; then
  metric "finance_topic_count" "$finance_topic_count" "PASS" "$RUN_DIR/kafka_topics.out"
else
  metric "finance_topic_count" "0" "WARN" "finance topics are absent after restart"
fi

p6_redis_key_count=$(redis-cli -h 127.0.0.1 --scan --pattern "$P6_REDIS_PATTERN" | wc -l | tr -d ' ')
p11_redis_key_count=$(redis-cli -h 127.0.0.1 --scan --pattern "$P11_REDIS_PATTERN" | wc -l | tr -d ' ')
if [[ "$p6_redis_key_count" -gt 0 ]]; then
  metric "p6_redis_key_count" "$p6_redis_key_count" "PASS" "$P6_REDIS_PATTERN"
else
  metric "p6_redis_key_count" "0" "WARN" "Redis latest-state keys may be volatile after restart"
fi
if [[ "$p11_redis_key_count" -gt 0 ]]; then
  metric "p11_redis_key_count" "$p11_redis_key_count" "PASS" "$P11_REDIS_PATTERN"
else
  metric "p11_redis_key_count" "0" "WARN" "Redis latest-state keys may be volatile after restart"
fi
step "realtime_restart_state" "PASS" "$RUN_DIR/realtime_restart_status.tsv"

required_status="PASS"
if grep -q $'\tFAIL\t' "$RUN_DIR/component_status.tsv" || grep -q $'\tFAIL$' "$RUN_DIR/table_counts.tsv"; then
  required_status="FAIL"
fi

warn_count=$(awk -F '\t' '$3 == "WARN" {c++} END {print c+0}' "$RUN_DIR/realtime_restart_status.tsv")
echo -e "metric\tvalue" > "$RUN_DIR/p15_status.tsv"
echo -e "run_name\t$RUN_NAME" >> "$RUN_DIR/p15_status.tsv"
echo -e "run_dir\t$RUN_DIR" >> "$RUN_DIR/p15_status.tsv"
echo -e "required_component_status\t$required_status" >> "$RUN_DIR/p15_status.tsv"
echo -e "realtime_warn_count\t$warn_count" >> "$RUN_DIR/p15_status.tsv"
echo -e "p15_status\t$required_status" >> "$RUN_DIR/p15_status.tsv"

cat > "$RUN_DIR/p15_summary.md" <<MD
# P15 Restart Readiness Summary

- Run name: \`$RUN_NAME\`
- Run dir: \`$RUN_DIR\`
- Required component status: \`$required_status\`
- Realtime warning count: \`$warn_count\`
- Status: \`$required_status\`

## Scope

P15 validates that the finance big-data project can recover required platform services after a VM restart. It checks HDFS/YARN, Hive, Kafka, Redis, Flink and Iceberg table counts. Redis historical latest-state keys are treated as WARN because they can be volatile after restart.

## Boundary

P15 does not rebuild business data, does not train models, does not process Medium/Large data, and does not replace P14 master validation.
MD

step "summary" "$required_status" "$RUN_DIR/p15_summary.md"

echo "P15_CLUSTER_RUN_DIR=$RUN_DIR"
echo "P15_STATUS=$required_status"
cat "$RUN_DIR/p15_status.tsv"

if [[ "$required_status" != "PASS" ]]; then
  exit 2
fi

