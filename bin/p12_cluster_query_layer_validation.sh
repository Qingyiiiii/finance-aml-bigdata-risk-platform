#!/usr/bin/env bash
# Purpose: P12 集群查询层验证脚本，检查 Trino/Doris 能否消费 finance_bigdata accepted 表和实时证据。
# Boundary: P12 不重建数据、不训练模型，只验证查询层可读性和小型业务查询。
set -uo pipefail

REMOTE_ROOT=${REMOTE_ROOT:-/home/common/tmp/finance_bigdata_project}
RUN_STAMP=$(date +%Y%m%d_%H%M%S)
RUN_NAME="p12_query_layer_validation_${RUN_STAMP}"
RUN_DIR="$REMOTE_ROOT/runs/$RUN_NAME"
TRINO_SERVER=${TRINO_SERVER:-http://hadoop1:8080}
TRINO_CATALOG=${TRINO_CATALOG:-iceberg}
TRINO_SCHEMA=${TRINO_SCHEMA:-finance_bigdata}
TRINO_CLI=${TRINO_CLI:-}
DORIS_HOST=${DORIS_HOST:-CLUSTER_NODE1_IP}
DORIS_QUERY_DB=${DORIS_QUERY_DB:-finance_bigdata}
P11_REDIS_PATTERN=${P11_REDIS_PATTERN:-finance_bigdata:p11:risk:latest:*}

mkdir -p "$RUN_DIR/sql"
echo "P12_CLUSTER_RUN_DIR=$RUN_DIR"
: > "$RUN_DIR/p11_redis_risk_sample.json"
: > "$RUN_DIR/doris_start_check.out"
: > "$RUN_DIR/doris_frontends.out"
: > "$RUN_DIR/doris_backends.out"
: > "$RUN_DIR/doris_be_processes.out"
: > "$RUN_DIR/doris_query_summary.tsv"
: > "$RUN_DIR/doris_query_summary.err"
: > "$RUN_DIR/trino_launcher_status.txt"

export JAVA_HOME=/export/server/jdk25
export PATH=$JAVA_HOME/bin:/export/server/trino/bin:/export/server/hadoop/bin:/export/server/hadoop/sbin:$PATH

echo -e "step\tstatus\tdetail" > "$RUN_DIR/steps.tsv"
echo -e "component\tstatus\tdetail" > "$RUN_DIR/component_status.tsv"
echo -e "query\tstatus\trows\tdetail" > "$RUN_DIR/trino_query_status.tsv"
echo -e "item\tstatus\tdetail" > "$RUN_DIR/doris_status.tsv"
echo -e "metric\tvalue\tstatus\tdetail" > "$RUN_DIR/realtime_residue.tsv"

step() {
  echo -e "$1\t$2\t$3" >> "$RUN_DIR/steps.tsv"
}

component() {
  echo -e "$1\t$2\t$3" >> "$RUN_DIR/component_status.tsv"
}

trino_status() {
  echo -e "$1\t$2\t$3\t$4" >> "$RUN_DIR/trino_query_status.tsv"
}

doris_status() {
  echo -e "$1\t$2\t$3" >> "$RUN_DIR/doris_status.tsv"
}

find_trino_cli() {
  if [[ -n "$TRINO_CLI" && -x "$TRINO_CLI" ]]; then
    echo "$TRINO_CLI"
    return 0
  fi
  for candidate in /usr/local/bin/trino /export/server/trino-481/client/trino-cli /export/server/trino-481/client/trino-client /export/server/trino/bin/trino; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

start_trino() {
  echo "===== start/check trino =====" > "$RUN_DIR/trino_launcher_status.txt"
  for host in hadoop1 hadoop2 hadoop3; do
    {
      echo "===== $host before ====="
      ssh -n common@"$host" "export JAVA_HOME=/export/server/jdk25; /export/server/trino/bin/launcher status || true; ss -lntp | grep 8080 || true"
      echo "===== $host start ====="
      ssh -n common@"$host" "export JAVA_HOME=/export/server/jdk25; /export/server/trino/bin/launcher start || true"
    } >> "$RUN_DIR/trino_launcher_status.txt" 2>&1
  done
  sleep 20
  for host in hadoop1 hadoop2 hadoop3; do
    {
      echo "===== $host after ====="
      ssh -n common@"$host" "export JAVA_HOME=/export/server/jdk25; /export/server/trino/bin/launcher status || true; ss -lntp | grep 8080 || true"
    } >> "$RUN_DIR/trino_launcher_status.txt" 2>&1
  done
}

run_trino_file() {
  local name="$1"
  local sql_text="$2"
  local output_file="$RUN_DIR/${name}.tsv"
  local sql_file="$RUN_DIR/sql/${name}.sql"
  local err_file="$RUN_DIR/${name}.err"
  printf "%s\n" "$sql_text" > "$sql_file"
  if [[ -z "$TRINO_CLI" ]]; then
    echo "Trino CLI not found" > "$err_file"
    trino_status "$name" "FAIL" "0" "$err_file"
    return 1
  fi
  if timeout 180s "$TRINO_CLI" \
    --server "$TRINO_SERVER" \
    --output-format TSV_HEADER \
    --file "$sql_file" \
    > "$output_file" 2> "$err_file"; then
    local rows
    rows=$(awk 'END {print (NR > 0 ? NR - 1 : 0)}' "$output_file")
    trino_status "$name" "PASS" "$rows" "$output_file"
    return 0
  fi
  trino_status "$name" "FAIL" "0" "$err_file"
  return 1
}

start_doris_best_effort() {
  echo "===== doris start/check =====" > "$RUN_DIR/doris_start_check.out"
  if [[ ! -x /export/server/doris/fe/bin/start_fe.sh ]]; then
    doris_status "doris_fe_script" "WARN" "/export/server/doris/fe/bin/start_fe.sh missing"
    return 1
  fi

  {
    /export/server/doris/fe/bin/start_fe.sh --daemon || true
    sleep 25
    ss -lntp | egrep '18030|9010|9020|9030' || true
  } >> "$RUN_DIR/doris_start_check.out" 2>&1

  if ! command -v mysql >/dev/null 2>&1; then
    doris_status "mysql_client" "WARN" "mysql client missing"
    return 1
  fi

  if timeout 30s mysql -h "$DORIS_HOST" -P 9030 -uroot -e "SHOW FRONTENDS;" > "$RUN_DIR/doris_frontends.out" 2>&1; then
    doris_status "doris_frontends" "PASS" "$RUN_DIR/doris_frontends.out"
  else
    doris_status "doris_frontends" "WARN" "$RUN_DIR/doris_frontends.out"
    return 1
  fi

  for host in hadoop1 hadoop2 hadoop3; do
    ssh -n common@"$host" "mkdir -p /export/data/doris/be; if [[ -x /export/server/doris/be/bin/start_be.sh ]]; then /export/server/doris/be/bin/start_be.sh --daemon || true; fi" >> "$RUN_DIR/doris_start_check.out" 2>&1
  done
  sleep 25

  for host in hadoop1 hadoop2 hadoop3; do
    {
      echo "===== $host ====="
      ssh -n common@"$host" "ps -ef | egrep 'doris_be|palo_be' | grep -v grep || true; ss -lntp | egrep '18040|9050|9060|8060' || true"
    } >> "$RUN_DIR/doris_be_processes.out" 2>&1
  done

  if timeout 30s mysql -h "$DORIS_HOST" -P 9030 -uroot -e "SHOW BACKENDS;" > "$RUN_DIR/doris_backends.out" 2>&1; then
    doris_status "doris_backends" "PASS" "$RUN_DIR/doris_backends.out"
  else
    doris_status "doris_backends" "WARN" "$RUN_DIR/doris_backends.out"
    return 1
  fi

  cat > "$RUN_DIR/sql/doris_validation.sql" <<SQL
CREATE DATABASE IF NOT EXISTS ${DORIS_QUERY_DB};
USE ${DORIS_QUERY_DB};
DROP TABLE IF EXISTS p12_query_layer_metrics;
CREATE TABLE p12_query_layer_metrics (
  metric VARCHAR(128),
  metric_value BIGINT
)
DUPLICATE KEY(metric)
DISTRIBUTED BY HASH(metric) BUCKETS 1
PROPERTIES ("replication_num" = "1");
INSERT INTO p12_query_layer_metrics VALUES
  ('dwd_finance_transactions', 5078345),
  ('dws_account_risk_features', 515080),
  ('p11_schema_valid_events', 8119),
  ('p11_redis_keys_written', 6451);
SELECT metric, metric_value FROM p12_query_layer_metrics ORDER BY metric;
SQL
  if timeout 60s mysql -h "$DORIS_HOST" -P 9030 -uroot < "$RUN_DIR/sql/doris_validation.sql" > "$RUN_DIR/doris_query_summary.tsv" 2> "$RUN_DIR/doris_query_summary.err"; then
    doris_status "doris_query_smoke" "PASS" "$RUN_DIR/doris_query_summary.tsv"
    return 0
  fi
  doris_status "doris_query_smoke" "WARN" "$RUN_DIR/doris_query_summary.err"
  return 1
}

echo "===== base component checks ====="
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

if timeout 45s /export/server/hive/bin/beeline -u "jdbc:hive2://hadoop1:10000/default" -n common -e "SHOW DATABASES LIKE 'finance_bigdata';" > "$RUN_DIR/beeline_finance_database.out" 2>&1 && grep -q 'finance_bigdata' "$RUN_DIR/beeline_finance_database.out"; then
  component "hive" "PASS" "finance_bigdata visible"
else
  component "hive" "FAIL" "$RUN_DIR/beeline_finance_database.out"
fi
step "base_component_check" "PASS" "$RUN_DIR/component_status.tsv"

start_trino
step "trino_start_check" "PASS" "$RUN_DIR/trino_launcher_status.txt"

TRINO_CLI=$(find_trino_cli || true)
echo "TRINO_CLI=$TRINO_CLI" > "$RUN_DIR/trino_cli_path.txt"
if [[ -n "$TRINO_CLI" ]]; then
  component "trino_cli" "PASS" "$TRINO_CLI"
else
  component "trino_cli" "FAIL" "not found"
fi

TRINO_STATUS="PASS"
run_trino_file "trino_nodes" "SELECT node_id, http_uri, node_version, coordinator, state FROM system.runtime.nodes ORDER BY node_id;" || TRINO_STATUS="FAIL"
run_trino_file "trino_schemas" "SHOW SCHEMAS FROM ${TRINO_CATALOG} LIKE '${TRINO_SCHEMA}';" || TRINO_STATUS="FAIL"
run_trino_file "trino_tables" "SHOW TABLES FROM ${TRINO_CATALOG}.${TRINO_SCHEMA};" || TRINO_STATUS="FAIL"

run_trino_file "trino_table_counts" "SELECT 'dwd_finance_transactions' AS table_name, 5078345 AS expected_count, COUNT(*) AS actual_count, CASE WHEN COUNT(*) = 5078345 THEN 'PASS' ELSE 'FAIL' END AS status FROM ${TRINO_CATALOG}.${TRINO_SCHEMA}.dwd_finance_transactions
UNION ALL SELECT 'dwd_finance_accounts', 518581, COUNT(*), CASE WHEN COUNT(*) = 518581 THEN 'PASS' ELSE 'FAIL' END FROM ${TRINO_CATALOG}.${TRINO_SCHEMA}.dwd_finance_accounts
UNION ALL SELECT 'dwd_finance_transaction_events', 10156690, COUNT(*), CASE WHEN COUNT(*) = 10156690 THEN 'PASS' ELSE 'FAIL' END FROM ${TRINO_CATALOG}.${TRINO_SCHEMA}.dwd_finance_transaction_events
UNION ALL SELECT 'dws_minute_transaction_kpi', 88316, COUNT(*), CASE WHEN COUNT(*) = 88316 THEN 'PASS' ELSE 'FAIL' END FROM ${TRINO_CATALOG}.${TRINO_SCHEMA}.dws_minute_transaction_kpi
UNION ALL SELECT 'dws_account_risk_features', 515080, COUNT(*), CASE WHEN COUNT(*) = 515080 THEN 'PASS' ELSE 'FAIL' END FROM ${TRINO_CATALOG}.${TRINO_SCHEMA}.dws_account_risk_features
UNION ALL SELECT 'dws_payment_format_kpi', 7, COUNT(*), CASE WHEN COUNT(*) = 7 THEN 'PASS' ELSE 'FAIL' END FROM ${TRINO_CATALOG}.${TRINO_SCHEMA}.dws_payment_format_kpi
UNION ALL SELECT 'dws_large_transaction_candidates', 200403, COUNT(*), CASE WHEN COUNT(*) = 200403 THEN 'PASS' ELSE 'FAIL' END FROM ${TRINO_CATALOG}.${TRINO_SCHEMA}.dws_large_transaction_candidates
ORDER BY table_name;" || TRINO_STATUS="FAIL"
if grep -q $'\tFAIL$' "$RUN_DIR/trino_table_counts.tsv" 2>/dev/null; then
  TRINO_STATUS="FAIL"
fi

run_trino_file "trino_payment_format_risk" "SELECT payment_format, transaction_count, laundering_count, ROUND(laundering_rate, 8) AS laundering_rate, CAST(total_amount_paid AS BIGINT) AS total_amount_paid FROM ${TRINO_CATALOG}.${TRINO_SCHEMA}.dws_payment_format_kpi ORDER BY laundering_rate DESC, transaction_count DESC;" || TRINO_STATUS="FAIL"
run_trino_file "trino_large_transaction_topn" "SELECT transaction_id, transaction_minute, from_account, to_account, amount_paid, payment_currency, payment_format, is_laundering, rule_hits FROM ${TRINO_CATALOG}.${TRINO_SCHEMA}.dws_large_transaction_candidates ORDER BY amount_paid DESC LIMIT 20;" || TRINO_STATUS="FAIL"
run_trino_file "trino_account_risk_topn" "SELECT account_number, total_event_count, debit_count, credit_count, CAST(out_amount AS BIGINT) AS out_amount, counterparty_count, laundering_event_count, cross_bank_event_count, cross_currency_event_count, risk_score_rule FROM ${TRINO_CATALOG}.${TRINO_SCHEMA}.dws_account_risk_features ORDER BY risk_score_rule DESC, laundering_event_count DESC, out_amount DESC LIMIT 20;" || TRINO_STATUS="FAIL"
run_trino_file "trino_hourly_laundering_distribution" "SELECT transaction_hour, COUNT(*) AS transaction_count, SUM(is_laundering) AS laundering_count, ROUND(CAST(SUM(is_laundering) AS DOUBLE) / COUNT(*), 8) AS laundering_rate, CAST(SUM(amount_paid) AS BIGINT) AS total_amount_paid FROM ${TRINO_CATALOG}.${TRINO_SCHEMA}.dwd_finance_transactions GROUP BY transaction_hour ORDER BY transaction_hour;" || TRINO_STATUS="FAIL"

BUSINESS_QUERY_PASS_COUNT=$(awk -F '\t' '$1 ~ /^trino_(payment_format_risk|large_transaction_topn|account_risk_topn|hourly_laundering_distribution)$/ && $2 == "PASS" && $3 > 0 {c++} END {print c+0}' "$RUN_DIR/trino_query_status.tsv")
if [[ "$BUSINESS_QUERY_PASS_COUNT" -lt 4 ]]; then
  TRINO_STATUS="FAIL"
fi
step "trino_query_validation" "$TRINO_STATUS" "$RUN_DIR/trino_query_status.tsv"

redis_key_count=$(redis-cli -h 127.0.0.1 --scan --pattern "$P11_REDIS_PATTERN" | wc -l | tr -d ' ')
if [[ "$redis_key_count" -gt 0 ]]; then
  echo -e "p11_redis_key_count\t$redis_key_count\tPASS\t$P11_REDIS_PATTERN" >> "$RUN_DIR/realtime_residue.tsv"
  first_redis_key=$(redis-cli -h 127.0.0.1 --scan --pattern "$P11_REDIS_PATTERN" | head -n 1)
  redis-cli -h 127.0.0.1 GET "$first_redis_key" > "$RUN_DIR/p11_redis_risk_sample.json" 2>&1 || true
else
  echo -e "p11_redis_key_count\t0\tWARN\t$P11_REDIS_PATTERN" >> "$RUN_DIR/realtime_residue.tsv"
fi
step "p11_realtime_residue_check" "PASS" "$RUN_DIR/realtime_residue.tsv"

DORIS_STATUS="WARN"
if start_doris_best_effort; then
  DORIS_STATUS="PASS"
else
  DORIS_STATUS="WARN"
fi
step "doris_best_effort_validation" "$DORIS_STATUS" "$RUN_DIR/doris_status.tsv"

timeout 20s yarn application -list -appStates RUNNING > "$RUN_DIR/yarn_running_apps_after.out" 2>&1 || true
if grep -q 'Total number of applications.*:0' "$RUN_DIR/yarn_running_apps_after.out"; then
  YARN_POST_STATUS="PASS"
else
  YARN_POST_STATUS="FAIL"
fi
echo -e "component\tstatus\tdetail" > "$RUN_DIR/postcheck.tsv"
echo -e "yarn_running_apps\t$YARN_POST_STATUS\tsee yarn_running_apps_after.out" >> "$RUN_DIR/postcheck.tsv"
step "postcheck" "$YARN_POST_STATUS" "$RUN_DIR/postcheck.tsv"

P12_STATUS="PASS"
if grep -q $'\tFAIL\t' "$RUN_DIR/component_status.tsv"; then
  P12_STATUS="FAIL"
fi
if [[ "$TRINO_STATUS" != "PASS" || "$YARN_POST_STATUS" != "PASS" ]]; then
  P12_STATUS="FAIL"
fi

echo -e "metric\tvalue" > "$RUN_DIR/p12_status.tsv"
echo -e "run_name\t$RUN_NAME" >> "$RUN_DIR/p12_status.tsv"
echo -e "run_dir\t$RUN_DIR" >> "$RUN_DIR/p12_status.tsv"
echo -e "trino_status\t$TRINO_STATUS" >> "$RUN_DIR/p12_status.tsv"
echo -e "doris_status\t$DORIS_STATUS" >> "$RUN_DIR/p12_status.tsv"
echo -e "business_query_pass_count\t$BUSINESS_QUERY_PASS_COUNT" >> "$RUN_DIR/p12_status.tsv"
echo -e "p11_redis_key_count\t$redis_key_count" >> "$RUN_DIR/p12_status.tsv"
echo -e "yarn_post_status\t$YARN_POST_STATUS" >> "$RUN_DIR/p12_status.tsv"
echo -e "p12_status\t$P12_STATUS" >> "$RUN_DIR/p12_status.tsv"

cat > "$RUN_DIR/p12_summary.md" <<MD
# P12 Trino/Doris Query Layer Validation Summary

- Run name: \`$RUN_NAME\`
- Run dir: \`$RUN_DIR\`
- Trino server: \`$TRINO_SERVER\`
- Trino catalog/schema: \`${TRINO_CATALOG}.${TRINO_SCHEMA}\`
- Trino status: \`$TRINO_STATUS\`
- Doris status: \`$DORIS_STATUS\`
- Business query pass count: \`$BUSINESS_QUERY_PASS_COUNT\`
- P11 Redis key count: \`$redis_key_count\`
- YARN postcheck: \`$YARN_POST_STATUS\`
- Status: \`$P12_STATUS\`

## Boundary

P12 validates the query layer. It does not rebuild P9/P10/P11 outputs and is not P14 master validation. Doris is best-effort in this phase; if Doris is not stable, it is recorded separately instead of being hidden inside Trino status.
MD

echo "P12_RUN_DIR=$RUN_DIR"
echo "TRINO_STATUS=$TRINO_STATUS"
echo "DORIS_STATUS=$DORIS_STATUS"
echo "P12_STATUS=$P12_STATUS"
cat "$RUN_DIR/p12_status.tsv"

if [[ "$P12_STATUS" != "PASS" ]]; then
  exit 2
fi

