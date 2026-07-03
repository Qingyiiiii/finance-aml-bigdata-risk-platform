#!/usr/bin/env bash
# Purpose: P6 demo 后置复核脚本，查看 P6 summary、Flink 残留、Redis 样本和 topic。
# Boundary: 只读复核，不重新消费、不重新写 Redis。
set -u

RUN_DIR=${1:-/home/common/tmp/finance_bigdata_project/runs/p6_realtime_demo_20260609_070436}
SUMMARY="$RUN_DIR/p6_summary.md"

echo "===== p6 summary ====="
cat "$SUMMARY"

echo "===== p6 flink jobs after cancel ====="
cat "$RUN_DIR/flink_jobs_after_cancel.txt" 2>/dev/null || true
/export/server/flink/bin/flink list -r || true

echo "===== p6 redis sample key ====="
FIRST_KEY=$(awk -F '\t' '$1=="sample_output" {print $2}' "$RUN_DIR/redis_set_summary.tsv" | xargs -I{} sh -c "head -n 1 '{}' | sed -n 's/.*\"event_account\":\"\\([^\"]*\\)\".*/finance_bigdata:risk:latest:\\1/p'")
if [[ -n "$FIRST_KEY" ]]; then
  redis-cli -h 127.0.0.1 GET "$FIRST_KEY"
fi

echo "===== p6 topics ====="
grep '^Input topic:' "$RUN_DIR/p6_summary.md" || true
grep '^Risk topic:' "$RUN_DIR/p6_summary.md" || true
/export/server/kafka/bin/kafka-topics.sh --bootstrap-server CLUSTER_NODE1_IP:9092 --list | grep '^finance\.' || true

echo "===== yarn running ====="
timeout 20s yarn application -list -appStates RUNNING || true

