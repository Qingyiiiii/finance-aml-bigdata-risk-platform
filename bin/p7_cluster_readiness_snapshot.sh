#!/usr/bin/env bash
# Purpose: P7 集群 readiness 快照脚本，采集组件、命名空间、Iceberg 表计数和 P6 实时残留。
# Boundary: P7 是只读快照，不创建新业务数据，也不等同于 P14 总验收。
set -uo pipefail

REMOTE_ROOT=${REMOTE_ROOT:-/home/common/tmp/finance_bigdata_project}
RUN_STAMP=$(date +%Y%m%d_%H%M%S)
RUN_NAME="p7_readiness_snapshot_${RUN_STAMP}"
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
  --conf spark.driver.port=37101
  --conf spark.blockManager.port=37102
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

P6_INPUT_TOPIC="finance.transactions.hi_small.20260609_070436"
P6_RISK_TOPIC="finance.risk.events.20260609_070436"
REDIS_PATTERN="finance_bigdata:risk:latest:*"

echo -e "component\tstatus\tdetail" > "$RUN_DIR/component_status.tsv"
echo -e "item\tstatus\tdetail" > "$RUN_DIR/namespace_snapshot.tsv"
echo -e "table_name\texpected_count\tactual_count\tstatus" > "$RUN_DIR/table_counts.tsv"
echo -e "metric\tvalue\tstatus\tdetail" > "$RUN_DIR/realtime_snapshot.tsv"
echo -e "step\tstatus\tdetail" > "$RUN_DIR/steps.tsv"

record_component() {
  echo -e "$1\t$2\t$3" >> "$RUN_DIR/component_status.tsv"
}

record_namespace() {
  echo -e "$1\t$2\t$3" >> "$RUN_DIR/namespace_snapshot.tsv"
}

record_realtime() {
  echo -e "$1\t$2\t$3\t$4" >> "$RUN_DIR/realtime_snapshot.tsv"
}

step_pass() {
  echo -e "$1\tPASS\t$2" >> "$RUN_DIR/steps.tsv"
}

echo "===== node snapshot ====="
for host in hadoop1 hadoop2 hadoop3; do
  {
    echo "===== $host ====="
    ssh -n common@$host "hostname; free -h; df -h /export; jps -l"
  } >> "$RUN_DIR/node_snapshot.txt" 2>&1
done
step_pass "node_snapshot" "$RUN_DIR/node_snapshot.txt"

if timeout 20s hdfs dfs -ls /lakehouse/projects/finance_bigdata > "$RUN_DIR/hdfs_ls_finance_bigdata.out" 2>&1; then
  record_component "hdfs" "PASS" "/lakehouse/projects/finance_bigdata readable"
  record_namespace "hdfs_root" "PASS" "/lakehouse/projects/finance_bigdata"
else
  record_component "hdfs" "FAIL" "cannot read /lakehouse/projects/finance_bigdata"
  record_namespace "hdfs_root" "FAIL" "/lakehouse/projects/finance_bigdata"
fi

if timeout 20s yarn node -list > "$RUN_DIR/yarn_nodes.out" 2>&1; then
  node_count=$(grep -c 'RUNNING' "$RUN_DIR/yarn_nodes.out" || true)
  if [[ "$node_count" -ge 3 ]]; then
    record_component "yarn_nodes" "PASS" "running_nodes=$node_count"
  else
    record_component "yarn_nodes" "FAIL" "running_nodes=$node_count"
  fi
else
  record_component "yarn_nodes" "FAIL" "yarn node -list failed"
fi

timeout 20s yarn application -list -appStates RUNNING > "$RUN_DIR/yarn_running_apps.out" 2>&1 || true
if grep -q 'Total number of applications.*:0' "$RUN_DIR/yarn_running_apps.out"; then
  record_component "yarn_running_apps" "PASS" "running_applications=0"
else
  record_component "yarn_running_apps" "FAIL" "running_applications_not_zero_or_unknown"
fi

if timeout 45s /export/server/hive/bin/beeline -u "jdbc:hive2://hadoop1:10000/default" -n common -e "SHOW DATABASES LIKE 'finance_bigdata';" > "$RUN_DIR/beeline_finance_database.out" 2>&1 && grep -q 'finance_bigdata' "$RUN_DIR/beeline_finance_database.out"; then
  record_component "hive" "PASS" "finance_bigdata visible via beeline"
  record_namespace "hive_database" "PASS" "finance_bigdata"
else
  record_component "hive" "FAIL" "finance_bigdata not visible via beeline"
  record_namespace "hive_database" "FAIL" "finance_bigdata"
fi

if /export/server/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server CLUSTER_NODE1_IP:9092 describe --status > "$RUN_DIR/kafka_quorum.out" 2>&1 && grep -q 'CurrentVoters' "$RUN_DIR/kafka_quorum.out"; then
  record_component "kafka" "PASS" "quorum status returned"
else
  record_component "kafka" "FAIL" "quorum status failed"
fi

if [[ "$(redis-cli -h 127.0.0.1 ping 2>/dev/null)" == "PONG" ]]; then
  record_component "redis" "PASS" "PING=PONG"
else
  record_component "redis" "FAIL" "PING failed"
fi

/export/server/flink/bin/flink list -r > "$RUN_DIR/flink_running_jobs.out" 2>&1 || true
if grep -q 'No running jobs' "$RUN_DIR/flink_running_jobs.out"; then
  record_component "flink_running_jobs" "PASS" "No running jobs"
else
  record_component "flink_running_jobs" "FAIL" "running jobs may exist"
fi
if jps -l | grep -q 'StandaloneSessionClusterEntrypoint'; then
  record_component "flink_service" "PASS" "JobManager process exists"
else
  record_component "flink_service" "FAIL" "JobManager process missing"
fi

if [[ -d "$REMOTE_ROOT" ]]; then
  record_namespace "linux_project_root" "PASS" "$REMOTE_ROOT"
else
  record_namespace "linux_project_root" "FAIL" "$REMOTE_ROOT missing"
fi

spark-sql "${SPARK_ARGS[@]}" -e "SHOW TABLES IN lakehouse.finance_bigdata;" > "$RUN_DIR/spark_show_tables.out" 2>&1
if grep -q 'dwd_finance_transactions' "$RUN_DIR/spark_show_tables.out"; then
  record_namespace "iceberg_namespace" "PASS" "lakehouse.finance_bigdata"
else
  record_namespace "iceberg_namespace" "FAIL" "lakehouse.finance_bigdata tables not visible"
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
step_pass "iceberg_table_counts" "$RUN_DIR/table_counts.tsv"

/export/server/kafka/bin/kafka-topics.sh --bootstrap-server CLUSTER_NODE1_IP:9092 --list > "$RUN_DIR/kafka_topics.out" 2>&1
finance_topic_count=$(grep -c '^finance' "$RUN_DIR/kafka_topics.out" || true)
record_namespace "kafka_finance_topic_count" "PASS" "$finance_topic_count"
if grep -qx "$P6_INPUT_TOPIC" "$RUN_DIR/kafka_topics.out"; then
  record_realtime "p6_input_topic" "$P6_INPUT_TOPIC" "PASS" "topic exists"
else
  record_realtime "p6_input_topic" "$P6_INPUT_TOPIC" "FAIL" "topic missing"
fi
if grep -qx "$P6_RISK_TOPIC" "$RUN_DIR/kafka_topics.out"; then
  record_realtime "p6_risk_topic" "$P6_RISK_TOPIC" "PASS" "topic exists"
else
  record_realtime "p6_risk_topic" "$P6_RISK_TOPIC" "FAIL" "topic missing"
fi

timeout 20s /export/server/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server CLUSTER_NODE1_IP:9092 \
  --topic "$P6_RISK_TOPIC" \
  --from-beginning \
  --max-messages 1 \
  > "$RUN_DIR/kafka_risk_topic_sample.jsonl" 2> "$RUN_DIR/kafka_risk_topic_sample.err" || true
if [[ -s "$RUN_DIR/kafka_risk_topic_sample.jsonl" ]]; then
  record_realtime "p6_risk_topic_sample" "1" "PASS" "$RUN_DIR/kafka_risk_topic_sample.jsonl"
else
  record_realtime "p6_risk_topic_sample" "0" "FAIL" "no risk topic sample consumed"
fi

redis_key_count=$(redis-cli -h 127.0.0.1 --scan --pattern "$REDIS_PATTERN" | wc -l | tr -d ' ')
if [[ "$redis_key_count" -gt 0 ]]; then
  record_namespace "redis_risk_key_count" "PASS" "$redis_key_count"
  record_realtime "redis_risk_keys" "$redis_key_count" "PASS" "$REDIS_PATTERN"
else
  record_namespace "redis_risk_key_count" "FAIL" "0"
  record_realtime "redis_risk_keys" "0" "FAIL" "$REDIS_PATTERN"
fi
first_redis_key=$(redis-cli -h 127.0.0.1 --scan --pattern "$REDIS_PATTERN" | head -n 1)
if [[ -n "$first_redis_key" ]]; then
  redis-cli -h 127.0.0.1 GET "$first_redis_key" > "$RUN_DIR/redis_risk_key_sample.json" 2>&1 || true
fi

if grep -q $'\tFAIL\t' "$RUN_DIR/component_status.tsv" || grep -q $'\tFAIL\t' "$RUN_DIR/namespace_snapshot.tsv" || grep -q $'\tFAIL$' "$RUN_DIR/table_counts.tsv" || grep -q $'\tFAIL\t' "$RUN_DIR/realtime_snapshot.tsv"; then
  overall_status="FAIL"
else
  overall_status="PASS"
fi

cat > "$RUN_DIR/p7_summary.md" <<MD
# P7 Readiness Snapshot Summary

- Run name: \`$RUN_NAME\`
- Run dir: \`$RUN_DIR\`
- Scope: platform and finance project readiness snapshot only
- Status: \`$overall_status\`

## Boundaries

- P7 does not create new business data.
- P7 does not equal P14 master validation.
- P7 verifies currently running platform components, finance namespace isolation, Iceberg table counts, P6 realtime residue, and local evidence after download.

## Main Evidence

- \`component_status.tsv\`
- \`namespace_snapshot.tsv\`
- \`table_counts.tsv\`
- \`realtime_snapshot.tsv\`
- \`node_snapshot.txt\`
MD

step_pass "summary" "$RUN_DIR/p7_summary.md"

echo "P7_CLUSTER_RUN_DIR=$RUN_DIR"
echo "P7_STATUS=$overall_status"
cat "$RUN_DIR/component_status.tsv"
cat "$RUN_DIR/table_counts.tsv"

if [[ "$overall_status" != "PASS" ]]; then
  exit 2
fi

