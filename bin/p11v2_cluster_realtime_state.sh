#!/usr/bin/env bash
set -euo pipefail

REMOTE_ROOT=${REMOTE_ROOT:-/home/common/tmp/finance_bigdata_project}
BASE_SAMPLE=${BASE_SAMPLE:-$REMOTE_ROOT/stage/p11v2_input/finance_p11v2_state_sample_10000.jsonl}
RUN_STAMP=$(date +%Y%m%d_%H%M%S)
TOPIC_STAMP=$(date +%Y%m%d%H%M%S)
RUN_NAME="p11v2_realtime_state_${RUN_STAMP}"
RUN_DIR="$REMOTE_ROOT/runs/$RUN_NAME"
RUN_SAMPLE="$RUN_DIR/finance_p11v2_state_${RUN_STAMP}.jsonl"
INPUT_TOPIC="finance.v2.p11.scoring.input.${TOPIC_STAMP}"
RISK_TOPIC="finance.v2.p11.risk.events.${TOPIC_STAMP}"
GROUP_ID="finance-v2-p11-${TOPIC_STAMP}"
BOOTSTRAP="CLUSTER_NODE1_IP:9092"
REDIS_PREFIX="finance_bigdata:v2:risk:latest"
HBASE_TABLE="finance_bigdata_v2:account_risk_state"

source /etc/profile.d/bigdata.sh 2>/dev/null || true
export JAVA_HOME=/export/server/jdk17
export PATH=$JAVA_HOME/bin:/export/server/kafka/bin:/export/server/flink/bin:/export/server/hadoop/bin:/export/server/hadoop/sbin:/export/server/hbase/bin:$PATH

mkdir -p "$RUN_DIR"
echo "P11V2_RUN_DIR=$RUN_DIR"
echo -e "step\tstatus\tdetail" > "$RUN_DIR/p11v2_steps.tsv"
: > "$RUN_DIR/flink_cancel.out"

step_pass() {
  echo -e "$1\tPASS\t$2" >> "$RUN_DIR/p11v2_steps.tsv"
}

test -s "$BASE_SAMPLE"
sed "s/P11V2_RUN_ID_PLACEHOLDER/$RUN_NAME/g" "$BASE_SAMPLE" > "$RUN_SAMPLE"
REPLAY_COUNT=$(wc -l < "$RUN_SAMPLE" | tr -d ' ')
echo "replay_count=$REPLAY_COUNT" > "$RUN_DIR/replay_count.txt"
step_pass "prepare_p11v2_sample" "$RUN_SAMPLE"

if [[ -s "$REMOTE_ROOT/contracts/p11v2_realtime_state_contract.md" ]]; then
  cp "$REMOTE_ROOT/contracts/p11v2_realtime_state_contract.md" "$RUN_DIR/p11v2_realtime_state_contract.md"
fi
step_pass "copy_p11v2_contract_doc" "$RUN_DIR/p11v2_realtime_state_contract.md"

hdfs dfsadmin -safemode get > "$RUN_DIR/hdfs_safemode.out" 2>&1 || true
if grep -qi 'Safe mode is ON' "$RUN_DIR/hdfs_safemode.out"; then
  hdfs dfsadmin -safemode leave >> "$RUN_DIR/hdfs_safemode.out" 2>&1 || true
fi
hdfs dfs -mkdir -p /lakehouse/services/hbase
hdfs dfs -chown -R common:supergroup /lakehouse/services/hbase
hdfs dfs -chmod -R 775 /lakehouse/services/hbase
step_pass "hdfs_hbase_root_ready" "/lakehouse/services/hbase"

for host in hadoop1 hadoop2 hadoop3; do
  ssh -n common@"$host" "/export/server/zookeeper/bin/zkServer.sh start >/tmp/p11v2_zk_start.out 2>&1 || true"
done
sleep 8
if ! jps -l | grep -q 'org.apache.hadoop.hbase.master.HMaster'; then
  /export/server/hbase/bin/start-hbase.sh > "$RUN_DIR/hbase_start.out" 2>&1 || true
else
  echo "HBase master already running" > "$RUN_DIR/hbase_start.out"
fi
sleep 25
for host in hadoop1 hadoop2 hadoop3; do
  {
    echo "===== $host ====="
    ssh -n common@"$host" "/export/server/zookeeper/bin/zkServer.sh status; jps -l | egrep 'HMaster|HRegionServer|QuorumPeerMain' || true"
  } >> "$RUN_DIR/hbase_process_snapshot.txt" 2>&1
done

/export/server/hbase/bin/hbase shell -n > "$RUN_DIR/hbase_status_before.txt" 2>&1 <<'HBASE'
status 'simple'
list_namespace
HBASE
step_pass "hbase_dependency_check" "$RUN_DIR/hbase_status_before.txt"

/export/server/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server "$BOOTSTRAP" describe --status > "$RUN_DIR/kafka_quorum.out" 2>&1
redis-cli -h 127.0.0.1 ping > "$RUN_DIR/redis_ping.out" 2>&1
/export/server/flink/bin/flink list -r > "$RUN_DIR/flink_jobs_before.txt" 2>&1 || true
if grep -Eq '[0-9a-f]{32}' "$RUN_DIR/flink_jobs_before.txt"; then
  echo "Existing Flink job detected; refusing to submit P11v2 state job" | tee "$RUN_DIR/flink_submit_error.txt"
  exit 3
fi
step_pass "realtime_dependency_check" "kafka,redis,flink,hbase"

/export/server/kafka/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --create --if-not-exists --topic "$INPUT_TOPIC" --partitions 1 --replication-factor 1
/export/server/kafka/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --create --if-not-exists --topic "$RISK_TOPIC" --partitions 1 --replication-factor 1
/export/server/kafka/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --describe --topic "$INPUT_TOPIC" > "$RUN_DIR/input_topic_describe.txt"
/export/server/kafka/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --describe --topic "$RISK_TOPIC" > "$RUN_DIR/risk_topic_describe.txt"
step_pass "create_p11v2_topics" "$INPUT_TOPIC,$RISK_TOPIC"

/export/server/kafka/bin/kafka-console-producer.sh --bootstrap-server "$BOOTSTRAP" --topic "$INPUT_TOPIC" < "$RUN_SAMPLE"
echo "producer_status=PASS" > "$RUN_DIR/producer_status.txt"
step_pass "produce_p11v2_sample" "$REPLAY_COUNT messages"

sed \
  -e "s|__RUN_ID__|$RUN_NAME|g" \
  -e "s|__INPUT_TOPIC__|$INPUT_TOPIC|g" \
  -e "s|__RISK_TOPIC__|$RISK_TOPIC|g" \
  -e "s|__GROUP_ID__|$GROUP_ID|g" \
  "$REMOTE_ROOT/streaming/finance_p11v2_state_flink.sql" > "$RUN_DIR/flink_p11v2_state.sql"

/export/server/flink/bin/sql-client.sh embedded -f "$RUN_DIR/flink_p11v2_state.sql" > "$RUN_DIR/flink_sql_submit.out" 2>&1
sleep 35
/export/server/flink/bin/flink list -r > "$RUN_DIR/flink_jobs_after_submit.txt" 2>&1 || true
step_pass "submit_flink_p11v2_state" "$RUN_DIR/flink_sql_submit.out"

timeout 90s /export/server/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server "$BOOTSTRAP" \
  --topic "$RISK_TOPIC" \
  --from-beginning \
  --timeout-ms 15000 \
  > "$RUN_DIR/risk_events_raw.jsonl" 2> "$RUN_DIR/risk_consumer.err" || true
step_pass "consume_p11v2_risk_topic" "$RUN_DIR/risk_events_raw.jsonl"

python3 "$REMOTE_ROOT/streaming/finance_collect_p11v2_state.py" \
  --input "$RUN_DIR/risk_events_raw.jsonl" \
  --run-id "$RUN_NAME" \
  --summary "$RUN_DIR/p11v2_state_summary.tsv" \
  --sample-output "$RUN_DIR/risk_events_sample.jsonl" \
  --invalid-output "$RUN_DIR/risk_events_invalid.jsonl" \
  --hbase-readback-output "$RUN_DIR/hbase_readback_sample.tsv" \
  --hbase-put-script "$RUN_DIR/hbase_puts.hbase" \
  --hbase-put-out "$RUN_DIR/hbase_put.out" \
  --hbase-put-err "$RUN_DIR/hbase_put.err" \
  --hbase-readback-script "$RUN_DIR/hbase_readback.hbase" \
  --hbase-readback-raw "$RUN_DIR/hbase_readback_raw.out" \
  --hbase-readback-err "$RUN_DIR/hbase_readback.err" \
  --redis-key-prefix "$REDIS_PREFIX"
step_pass "validate_schema_write_redis_hbase" "$RUN_DIR/p11v2_state_summary.tsv"

grep -Eo '[0-9a-f]{32}' "$RUN_DIR/flink_jobs_after_submit.txt" | sort -u > "$RUN_DIR/flink_job_ids_to_cancel.txt" || true
while read -r job_id; do
  if [[ -n "$job_id" ]]; then
    /export/server/flink/bin/flink cancel "$job_id" >> "$RUN_DIR/flink_cancel.out" 2>&1 || true
  fi
done < "$RUN_DIR/flink_job_ids_to_cancel.txt"
sleep 5
/export/server/flink/bin/flink list -r > "$RUN_DIR/flink_jobs_after_cancel.txt" 2>&1 || true
if grep -q 'No running jobs' "$RUN_DIR/flink_jobs_after_cancel.txt"; then
  flink_post_status="PASS"
else
  flink_post_status="FAIL"
fi

timeout 20s yarn application -list -appStates RUNNING > "$RUN_DIR/yarn_running_apps_after.out" 2>&1 || true
if grep -q 'Total number of applications.*:0' "$RUN_DIR/yarn_running_apps_after.out"; then
  yarn_post_status="PASS"
else
  yarn_post_status="FAIL"
fi

/export/server/hbase/bin/hbase shell -n > "$RUN_DIR/hbase_status_after.txt" 2>&1 <<HBASE
status 'simple'
count '$HBASE_TABLE', INTERVAL => 10000
HBASE

echo -e "component\tstatus\tdetail" > "$RUN_DIR/postcheck.tsv"
echo -e "flink_running_jobs\t$flink_post_status\tsee flink_jobs_after_cancel.txt" >> "$RUN_DIR/postcheck.tsv"
echo -e "yarn_running_apps\t$yarn_post_status\tsee yarn_running_apps_after.out" >> "$RUN_DIR/postcheck.tsv"
step_pass "postcheck" "$RUN_DIR/postcheck.tsv"

RAW_EVENTS=$(awk -F '\t' '$1=="raw_event_count" {print $2}' "$RUN_DIR/p11v2_state_summary.tsv")
VALID_EVENTS=$(awk -F '\t' '$1=="schema_valid_event_count" {print $2}' "$RUN_DIR/p11v2_state_summary.tsv")
INVALID_EVENTS=$(awk -F '\t' '$1=="schema_invalid_event_count" {print $2}' "$RUN_DIR/p11v2_state_summary.tsv")
REDIS_KEYS_WRITTEN=$(awk -F '\t' '$1=="redis_keys_written" {print $2}' "$RUN_DIR/p11v2_state_summary.tsv")
HBASE_ROWS_WRITTEN=$(awk -F '\t' '$1=="hbase_rows_written" {print $2}' "$RUN_DIR/p11v2_state_summary.tsv")
CONSISTENCY_FAILS=$(awk -F '\t' '$1=="redis_hbase_consistency_fail_count" {print $2}' "$RUN_DIR/p11v2_state_summary.tsv")
RAW_EVENTS=${RAW_EVENTS:-0}
VALID_EVENTS=${VALID_EVENTS:-0}
INVALID_EVENTS=${INVALID_EVENTS:-1}
REDIS_KEYS_WRITTEN=${REDIS_KEYS_WRITTEN:-0}
HBASE_ROWS_WRITTEN=${HBASE_ROWS_WRITTEN:-0}
CONSISTENCY_FAILS=${CONSISTENCY_FAILS:-1}

overall_status="PASS"
if [[ "$RAW_EVENTS" -le 0 || "$VALID_EVENTS" -le 0 || "$INVALID_EVENTS" -ne 0 || "$REDIS_KEYS_WRITTEN" -le 0 || "$HBASE_ROWS_WRITTEN" -le 0 || "$CONSISTENCY_FAILS" -ne 0 ]]; then
  overall_status="FAIL"
fi
if grep -q $'\tFAIL\t' "$RUN_DIR/postcheck.tsv"; then
  overall_status="FAIL"
fi

cat > "$RUN_DIR/p11v2_summary.md" <<MD
# P11v2 Realtime State Summary

- Run name: \`$RUN_NAME\`
- Run dir: \`$RUN_DIR\`
- Input topic: \`$INPUT_TOPIC\`
- Risk topic: \`$RISK_TOPIC\`
- Redis key prefix: \`$REDIS_PREFIX\`
- HBase table: \`$HBASE_TABLE\`
- Replay messages: \`$REPLAY_COUNT\`
- Raw risk events: \`$RAW_EVENTS\`
- Schema valid events: \`$VALID_EVENTS\`
- Schema invalid events: \`$INVALID_EVENTS\`
- Redis latest-state keys written: \`$REDIS_KEYS_WRITTEN\`
- HBase durable state rows written: \`$HBASE_ROWS_WRITTEN\`
- Redis/HBase consistency failures: \`$CONSISTENCY_FAILS\`
- Status: \`$overall_status\`

## Boundary

P11v2 verifies Kafka/Flink risk scoring plus Redis cache and HBase durable account risk state. It does not start ClickHouse or Elasticsearch as PASS blockers, does not build BI, and is not P14v2 validation.
MD

echo "P11V2_RUN_DIR=$RUN_DIR"
echo "P11V2_INPUT_TOPIC=$INPUT_TOPIC"
echo "P11V2_RISK_TOPIC=$RISK_TOPIC"
echo "P11V2_STATUS=$overall_status"
cat "$RUN_DIR/p11v2_state_summary.tsv"
cat "$RUN_DIR/postcheck.tsv"

if [[ "$overall_status" != "PASS" ]]; then
  exit 2
fi

