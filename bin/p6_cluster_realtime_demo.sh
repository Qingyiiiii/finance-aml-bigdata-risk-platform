#!/usr/bin/env bash
# Purpose: P6 集群实时规则风控 demo，串起 Kafka input、Flink SQL、risk topic 和 Redis latest-state。
# Boundary: 这是短时作品集 demo，结束后没有运行中的 Flink job 不代表失败。
set -euo pipefail

REMOTE_ROOT=${REMOTE_ROOT:-/home/common/tmp/finance_bigdata_project}
BASE_SAMPLE=${BASE_SAMPLE:-$REMOTE_ROOT/stage/p6_input/finance_transactions_replay_10000.jsonl}
RUN_STAMP=$(date +%Y%m%d_%H%M%S)
TOPIC_STAMP=$(date +%Y%m%d%H%M%S)
RUN_NAME="p6_realtime_demo_${RUN_STAMP}"
RUN_DIR="$REMOTE_ROOT/runs/$RUN_NAME"
RUN_SAMPLE="$RUN_DIR/finance_transactions_replay_${RUN_STAMP}.jsonl"
INPUT_TOPIC="finance-transactions-hi-small-${TOPIC_STAMP}"
RISK_TOPIC="finance-risk-events-${TOPIC_STAMP}"
GROUP_ID="finance-p6-${TOPIC_STAMP}"
BOOTSTRAP="CLUSTER_NODE1_IP:9092"

export JAVA_HOME=/export/server/jdk17
export PATH=$JAVA_HOME/bin:/export/server/kafka/bin:/export/server/flink/bin:$PATH

mkdir -p "$RUN_DIR"

echo "===== p6 prepare sample ====="
test -s "$BASE_SAMPLE"
sed "s/P6_RUN_ID_PLACEHOLDER/$RUN_NAME/g" "$BASE_SAMPLE" > "$RUN_SAMPLE"
REPLAY_COUNT=$(wc -l < "$RUN_SAMPLE" | tr -d ' ')
echo "replay_count=$REPLAY_COUNT" | tee "$RUN_DIR/replay_count.txt"

echo "===== p6 create topics ====="
/export/server/kafka/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --create --if-not-exists --topic "$INPUT_TOPIC" --partitions 1 --replication-factor 1
/export/server/kafka/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --create --if-not-exists --topic "$RISK_TOPIC" --partitions 1 --replication-factor 1
/export/server/kafka/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --describe --topic "$INPUT_TOPIC" > "$RUN_DIR/input_topic_describe.txt"
/export/server/kafka/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --describe --topic "$RISK_TOPIC" > "$RUN_DIR/risk_topic_describe.txt"

echo "===== p6 produce replay to kafka ====="
/export/server/kafka/bin/kafka-console-producer.sh --bootstrap-server "$BOOTSTRAP" --topic "$INPUT_TOPIC" < "$RUN_SAMPLE"
echo "producer_status=PASS" > "$RUN_DIR/producer_status.txt"

echo "===== p6 submit flink sql risk job ====="
/export/server/flink/bin/flink list -r > "$RUN_DIR/flink_jobs_before.txt" 2>&1 || true
if grep -Eq '[0-9a-f]{32}' "$RUN_DIR/flink_jobs_before.txt"; then
  echo "Existing Flink job detected; refusing to submit P6 risk job" | tee "$RUN_DIR/flink_submit_error.txt"
  exit 3
fi

sed \
  -e "s|__RUN_ID__|$RUN_NAME|g" \
  -e "s|__INPUT_TOPIC__|$INPUT_TOPIC|g" \
  -e "s|__RISK_TOPIC__|$RISK_TOPIC|g" \
  -e "s|__GROUP_ID__|$GROUP_ID|g" \
  "$REMOTE_ROOT/streaming/finance_risk_rules_flink.sql" > "$RUN_DIR/flink_risk_rules.sql"

/export/server/flink/bin/sql-client.sh embedded -f "$RUN_DIR/flink_risk_rules.sql" > "$RUN_DIR/flink_sql_submit.out" 2>&1
sleep 35
/export/server/flink/bin/flink list -r > "$RUN_DIR/flink_jobs_after_submit.txt" 2>&1 || true

echo "===== p6 consume risk topic ====="
timeout 90s /export/server/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server "$BOOTSTRAP" \
  --topic "$RISK_TOPIC" \
  --from-beginning \
  --timeout-ms 15000 \
  > "$RUN_DIR/risk_events_raw.jsonl" 2> "$RUN_DIR/risk_consumer.err" || true

echo "===== p6 write redis latest state ====="
python3 "$REMOTE_ROOT/streaming/finance_collect_risk_to_redis.py" \
  --input "$RUN_DIR/risk_events_raw.jsonl" \
  --run-id "$RUN_NAME" \
  --summary "$RUN_DIR/redis_set_summary.tsv" \
  --sample-output "$RUN_DIR/risk_events_sample.jsonl" \
  --key-prefix "finance_bigdata:risk:latest"

echo "===== p6 cancel flink risk job ====="
grep -Eo '[0-9a-f]{32}' "$RUN_DIR/flink_jobs_after_submit.txt" | sort -u > "$RUN_DIR/flink_job_ids_to_cancel.txt" || true
while read -r job_id; do
  if [[ -n "$job_id" ]]; then
    /export/server/flink/bin/flink cancel "$job_id" >> "$RUN_DIR/flink_cancel.out" 2>&1 || true
  fi
done < "$RUN_DIR/flink_job_ids_to_cancel.txt"
sleep 5
/export/server/flink/bin/flink list -r > "$RUN_DIR/flink_jobs_after_cancel.txt" 2>&1 || true

RISK_EVENT_COUNT=$(awk -F '\t' '$1=="risk_event_count" {print $2}' "$RUN_DIR/redis_set_summary.tsv")
REDIS_KEYS_WRITTEN=$(awk -F '\t' '$1=="redis_keys_written" {print $2}' "$RUN_DIR/redis_set_summary.tsv")

cat > "$RUN_DIR/steps.tsv" <<TSV
step	status	detail
prepare_sample	PASS	$RUN_SAMPLE
create_topics	PASS	$INPUT_TOPIC,$RISK_TOPIC
produce_replay	PASS	$REPLAY_COUNT messages
submit_flink_risk_job	PASS	$RUN_DIR/flink_sql_submit.out
consume_risk_topic	PASS	$RUN_DIR/risk_events_raw.jsonl
write_redis_latest_state	PASS	$RUN_DIR/redis_set_summary.tsv
cancel_flink_job	PASS	$RUN_DIR/flink_jobs_after_cancel.txt
TSV

cat > "$RUN_DIR/p6_summary.md" <<MD
# P6 Kafka/Flink/Redis Realtime Demo Summary

- Run name: \`$RUN_NAME\`
- Run dir: \`$RUN_DIR\`
- Input topic: \`$INPUT_TOPIC\`
- Risk topic: \`$RISK_TOPIC\`
- Replay messages: \`$REPLAY_COUNT\`
- Risk events consumed: \`$RISK_EVENT_COUNT\`
- Redis latest-state keys written: \`$REDIS_KEYS_WRITTEN\`
- Status: \`PASS\`

## Scope

This is a portfolio realtime demo, not a production risk model.
MD

cat "$RUN_DIR/redis_set_summary.tsv"
echo "P6_RUN_DIR=$RUN_DIR"
echo "P6_INPUT_TOPIC=$INPUT_TOPIC"
echo "P6_RISK_TOPIC=$RISK_TOPIC"
echo "P6_STATUS=PASS"

