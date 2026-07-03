#!/usr/bin/env bash
set -euo pipefail

REMOTE_ROOT=${REMOTE_ROOT:-/home/common/tmp/finance_bigdata_project}
RUN_STAMP=$(date +%Y%m%d_%H%M%S)
RUN_NAME="p12v2_query_investigation_${RUN_STAMP}"
RUN_DIR="$REMOTE_ROOT/runs/$RUN_NAME"
P11V2_SOURCE_RUN_DIR=${P11V2_SOURCE_RUN_DIR:-}
TRINO_SERVER=${TRINO_SERVER:-http://hadoop1:18080}
TRINO_CATALOG=${TRINO_CATALOG:-iceberg}
TRINO_SCHEMA=${TRINO_SCHEMA:-finance_bigdata}
CLICKHOUSE_DB=${CLICKHOUSE_DB:-finance_bigdata_v2}
CLICKHOUSE_ADS_TABLE=${CLICKHOUSE_ADS_TABLE:-finance_bigdata_v2.ads_account_risk_features}
CLICKHOUSE_EVENTS_TABLE=${CLICKHOUSE_EVENTS_TABLE:-finance_bigdata_v2.ads_p11v2_risk_events}
ES_INDEX=${ES_INDEX:-finance-risk-events-v2}
ES_CA=${ES_CA:-/export/server/elasticsearch/config/certs/ca/ca.crt}

mkdir -p "$RUN_DIR/sql"
echo "P12V2_RUN_DIR=$RUN_DIR"

CREDENTIALS_FILE="$(mktemp /tmp/finance_p12v2_credentials.XXXXXX)"
cleanup_credentials() {
  shred -u "$CREDENTIALS_FILE" >/dev/null 2>&1 || rm -f "$CREDENTIALS_FILE"
}
trap cleanup_credentials EXIT
chmod 600 "$CREDENTIALS_FILE"
cat > "$CREDENTIALS_FILE" || true
set -a
source "$CREDENTIALS_FILE" 2>/dev/null || true
set +a

sudo_run() {
  if [[ -n "${CLUSTER_HADOOP_COMMON_PASSWORD:-}" ]]; then
    printf '%s\n' "$CLUSTER_HADOOP_COMMON_PASSWORD" | sudo -S -p '' "$@"
  else
    sudo -n "$@"
  fi
}

echo -e "step\tstatus\tdetail" > "$RUN_DIR/p12v2_steps.tsv"
echo -e "component\tstatus\tdetail" > "$RUN_DIR/component_status.tsv"
echo -e "metric\tvalue\tstatus\tdetail" > "$RUN_DIR/p11v2_source_reference.tsv"
echo -e "query\tstatus\trows\tdetail" > "$RUN_DIR/trino_query_status.tsv"
echo -e "query\tstatus\trows\tdetail" > "$RUN_DIR/clickhouse_query_status.tsv"
echo -e "item\tstatus\tvalue\tdetail" > "$RUN_DIR/elasticsearch_index_status.tsv"
: > "$RUN_DIR/elasticsearch_bulk_response.json"
: > "$RUN_DIR/elasticsearch_search_sample.json"
: > "$RUN_DIR/elasticsearch_health.json"
: > "$RUN_DIR/elasticsearch_count.json"

step() {
  echo -e "$1\t$2\t$3" >> "$RUN_DIR/p12v2_steps.tsv"
}

component() {
  echo -e "$1\t$2\t$3" >> "$RUN_DIR/component_status.tsv"
}

source_metric() {
  echo -e "$1\t$2\t$3\t$4" >> "$RUN_DIR/p11v2_source_reference.tsv"
}

trino_status() {
  echo -e "$1\t$2\t$3\t$4" >> "$RUN_DIR/trino_query_status.tsv"
}

clickhouse_status() {
  echo -e "$1\t$2\t$3\t$4" >> "$RUN_DIR/clickhouse_query_status.tsv"
}

es_status() {
  echo -e "$1\t$2\t$3\t$4" >> "$RUN_DIR/elasticsearch_index_status.tsv"
}

find_latest_p11v2_run() {
  find "$REMOTE_ROOT/runs" -maxdepth 1 -type d -name 'p11v2_realtime_state_*' 2>/dev/null | sort -r | while read -r candidate; do
    if [[ -s "$candidate/p11v2_state_summary.tsv" ]] && grep -q $'^schema_invalid_event_count\t0$' "$candidate/p11v2_state_summary.tsv"; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

if [[ -z "$P11V2_SOURCE_RUN_DIR" ]]; then
  P11V2_SOURCE_RUN_DIR="$(find_latest_p11v2_run || true)"
fi

if [[ -z "$P11V2_SOURCE_RUN_DIR" || ! -s "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv" ]]; then
  source_metric "p11v2_source_run_dir" "${P11V2_SOURCE_RUN_DIR:-MISSING}" "FAIL" "p11v2_state_summary.tsv missing"
  echo "P11v2 accepted evidence not found" >&2
  exit 2
fi

P11V2_RAW_EVENTS=$(awk -F '\t' '$1=="raw_event_count" {print $2}' "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv")
P11V2_VALID_EVENTS=$(awk -F '\t' '$1=="schema_valid_event_count" {print $2}' "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv")
P11V2_INVALID_EVENTS=$(awk -F '\t' '$1=="schema_invalid_event_count" {print $2}' "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv")
P11V2_REDIS_KEYS=$(awk -F '\t' '$1=="redis_keys_written" {print $2}' "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv")
P11V2_HBASE_ROWS=$(awk -F '\t' '$1=="hbase_rows_written" {print $2}' "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv")
P11V2_CONSISTENCY_FAILS=$(awk -F '\t' '$1=="redis_hbase_consistency_fail_count" {print $2}' "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv")
P11V2_RAW_EVENTS=${P11V2_RAW_EVENTS:-0}
P11V2_VALID_EVENTS=${P11V2_VALID_EVENTS:-0}
P11V2_INVALID_EVENTS=${P11V2_INVALID_EVENTS:-1}
P11V2_REDIS_KEYS=${P11V2_REDIS_KEYS:-0}
P11V2_HBASE_ROWS=${P11V2_HBASE_ROWS:-0}
P11V2_CONSISTENCY_FAILS=${P11V2_CONSISTENCY_FAILS:-1}

P11V2_SOURCE_STATUS="PASS"
if [[ "$P11V2_RAW_EVENTS" -le 0 || "$P11V2_VALID_EVENTS" -le 0 || "$P11V2_INVALID_EVENTS" -ne 0 || "$P11V2_REDIS_KEYS" -le 0 || "$P11V2_HBASE_ROWS" -le 0 || "$P11V2_CONSISTENCY_FAILS" -ne 0 ]]; then
  P11V2_SOURCE_STATUS="FAIL"
fi
source_metric "p11v2_source_run_dir" "$P11V2_SOURCE_RUN_DIR" "$P11V2_SOURCE_STATUS" "locked source"
source_metric "p11v2_raw_event_count" "$P11V2_RAW_EVENTS" "$P11V2_SOURCE_STATUS" "$P11V2_SOURCE_RUN_DIR/risk_events_raw.jsonl"
source_metric "p11v2_schema_valid_event_count" "$P11V2_VALID_EVENTS" "$P11V2_SOURCE_STATUS" "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv"
source_metric "p11v2_schema_invalid_event_count" "$P11V2_INVALID_EVENTS" "$P11V2_SOURCE_STATUS" "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv"
source_metric "p11v2_hbase_rows_written" "$P11V2_HBASE_ROWS" "$P11V2_SOURCE_STATUS" "$P11V2_SOURCE_RUN_DIR/hbase_readback_sample.tsv"
step "lock_p11v2_source" "$P11V2_SOURCE_STATUS" "$P11V2_SOURCE_RUN_DIR"

source /etc/profile.d/bigdata.sh 2>/dev/null || true

export JAVA_HOME=/export/server/jdk25
export PATH=$JAVA_HOME/bin:/export/server/trino/bin:/export/server/hadoop/bin:/export/server/hadoop/sbin:$PATH

find_trino_cli() {
  for candidate in /usr/local/bin/trino /export/server/trino-481/client/trino-cli /export/server/trino-481/client/trino-client /export/server/trino/bin/trino; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

start_trino() {
  echo "===== start/check p12v2 temp trino coordinator =====" > "$RUN_DIR/trino_launcher_status.txt"
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
    echo "===== hadoop1 existing port 8080/18080 before ====="
    ss -lntp | egrep '8080|18080' || true
    echo "===== temp config ====="
    grep -nE 'coordinator|node-scheduler.include-coordinator|http-server.http.port|discovery.uri' "$TEMP_TRINO_ETC/config.properties" || true
    echo "===== start temp coordinator ====="
    /export/server/trino/bin/launcher -etc-dir "$TEMP_TRINO_ETC" -data-dir "$TEMP_TRINO_DATA" start || true
  } >> "$RUN_DIR/trino_launcher_status.txt" 2>&1
  sleep 25
  {
    echo "===== temp status after ====="
    /export/server/trino/bin/launcher -etc-dir "$TEMP_TRINO_ETC" -data-dir "$TEMP_TRINO_DATA" status || true
    ss -lntp | egrep '8080|18080' || true
    tail -n 120 "$TEMP_TRINO_DATA/var/log/server.log" 2>/dev/null || true
  } >> "$RUN_DIR/trino_launcher_status.txt" 2>&1
}

stop_temp_trino() {
  if [[ -n "${TEMP_TRINO_ETC:-}" && -n "${TEMP_TRINO_DATA:-}" ]]; then
    /export/server/trino/bin/launcher -etc-dir "$TEMP_TRINO_ETC" -data-dir "$TEMP_TRINO_DATA" stop >> "$RUN_DIR/trino_launcher_status.txt" 2>&1 || true
  fi
}

run_trino_file() {
  local name="$1"
  local sql_text="$2"
  local output_file="$RUN_DIR/${name}.tsv"
  local sql_file="$RUN_DIR/sql/${name}.sql"
  local err_file="$RUN_DIR/${name}.err"
  printf "%s\n" "$sql_text" > "$sql_file"
  if [[ -z "${TRINO_CLI:-}" ]]; then
    echo "Trino CLI not found" > "$err_file"
    trino_status "$name" "FAIL" "0" "$err_file"
    return 1
  fi
  if timeout 240s "$TRINO_CLI" --server "$TRINO_SERVER" --output-format TSV_HEADER --file "$sql_file" > "$output_file" 2> "$err_file"; then
    local rows
    rows=$(awk 'END {print (NR > 0 ? NR - 1 : 0)}' "$output_file")
    if [[ "$rows" -gt 0 ]]; then
      trino_status "$name" "PASS" "$rows" "$output_file"
      return 0
    fi
    trino_status "$name" "FAIL" "$rows" "$output_file"
    return 1
  fi
  trino_status "$name" "FAIL" "0" "$err_file"
  return 1
}

run_clickhouse_query() {
  local name="$1"
  local sql_text="$2"
  local output_file="$RUN_DIR/${name}.tsv"
  local err_file="$RUN_DIR/${name}.err"
  if clickhouse-client --query "$sql_text FORMAT TSVWithNames" > "$output_file" 2> "$err_file"; then
    local rows
    rows=$(awk 'END {print (NR > 0 ? NR - 1 : 0)}' "$output_file")
    if [[ "$rows" -gt 0 ]]; then
      clickhouse_status "$name" "PASS" "$rows" "$output_file"
      return 0
    fi
    clickhouse_status "$name" "FAIL" "$rows" "$output_file"
    return 1
  fi
  clickhouse_status "$name" "FAIL" "0" "$err_file"
  return 1
}

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

start_trino
TRINO_CLI="$(find_trino_cli || true)"
echo "TRINO_CLI=$TRINO_CLI" > "$RUN_DIR/trino_cli_path.txt"
if [[ -n "$TRINO_CLI" ]]; then
  component "trino_cli" "PASS" "$TRINO_CLI"
else
  component "trino_cli" "FAIL" "not found"
fi

TRINO_STATUS="PASS"
run_trino_file "trino_nodes" "SELECT node_id, http_uri, node_version, coordinator, state FROM system.runtime.nodes ORDER BY node_id;" || TRINO_STATUS="FAIL"
run_trino_file "trino_table_counts" "SELECT 'dws_account_risk_features' AS table_name, COUNT(*) AS actual_count FROM ${TRINO_CATALOG}.${TRINO_SCHEMA}.dws_account_risk_features
UNION ALL SELECT 'dws_payment_format_kpi', COUNT(*) FROM ${TRINO_CATALOG}.${TRINO_SCHEMA}.dws_payment_format_kpi
UNION ALL SELECT 'dwd_finance_transactions', COUNT(*) FROM ${TRINO_CATALOG}.${TRINO_SCHEMA}.dwd_finance_transactions
ORDER BY table_name;" || TRINO_STATUS="FAIL"

TRINO_EXPORT_SQL="SELECT
  CAST(account_number AS varchar) AS account_number,
  CAST(total_event_count AS bigint) AS total_event_count,
  CAST(debit_count AS bigint) AS debit_count,
  CAST(credit_count AS bigint) AS credit_count,
  CAST(out_amount AS decimal(20,2)) AS out_amount,
  CAST(counterparty_count AS bigint) AS counterparty_count,
  CAST(laundering_event_count AS bigint) AS laundering_event_count,
  CAST(cross_bank_event_count AS bigint) AS cross_bank_event_count,
  CAST(cross_currency_event_count AS bigint) AS cross_currency_event_count,
  CAST(risk_score_rule AS double) AS risk_score_rule,
  format_datetime(current_timestamp, 'yyyy-MM-dd HH:mm:ss') AS updated_at
FROM ${TRINO_CATALOG}.${TRINO_SCHEMA}.dws_account_risk_features
ORDER BY risk_score_rule DESC, laundering_event_count DESC, out_amount DESC
LIMIT 5000;"
run_trino_file "clickhouse_ads_account_risk_features_source" "$TRINO_EXPORT_SQL" || TRINO_STATUS="FAIL"
step "trino_source_query" "$TRINO_STATUS" "$RUN_DIR/trino_query_status.tsv"

if systemctl is-active --quiet clickhouse-server; then
  echo "clickhouse already active" > "$RUN_DIR/clickhouse_service.out"
else
  sudo_run systemctl start clickhouse-server > "$RUN_DIR/clickhouse_service.out" 2>&1 || true
fi
sleep 5
if clickhouse-client --query "SELECT version()" > "$RUN_DIR/clickhouse_version.txt" 2> "$RUN_DIR/clickhouse_version.err"; then
  component "clickhouse_service" "PASS" "$RUN_DIR/clickhouse_version.txt"
else
  component "clickhouse_service" "FAIL" "$RUN_DIR/clickhouse_version.err"
fi

CLICKHOUSE_STATUS="PASS"
clickhouse-client --query "CREATE DATABASE IF NOT EXISTS ${CLICKHOUSE_DB}"
clickhouse-client --query "
CREATE TABLE IF NOT EXISTS ${CLICKHOUSE_ADS_TABLE}
(
    account_number String,
    total_event_count UInt64,
    debit_count UInt64,
    credit_count UInt64,
    out_amount Decimal(20, 2),
    counterparty_count UInt64,
    laundering_event_count UInt64,
    cross_bank_event_count UInt64,
    cross_currency_event_count UInt64,
    risk_score_rule Float64,
    updated_at DateTime
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(updated_at)
ORDER BY (account_number, risk_score_rule)"
clickhouse-client --query "
CREATE TABLE IF NOT EXISTS ${CLICKHOUSE_EVENTS_TABLE}
(
    run_id String,
    contract_version String,
    transaction_id String,
    event_time String,
    event_account String,
    counterparty_account String,
    amount_paid Float64,
    payment_currency String,
    payment_format String,
    feature_snapshot_version String,
    risk_score UInt16,
    risk_level String,
    risk_reasons String,
    rule_hits String,
    state_operation String,
    state_store_version String,
    scored_at String,
    ingested_at DateTime DEFAULT now()
)
ENGINE = MergeTree
ORDER BY (run_id, event_account, transaction_id)"

if [[ "$TRINO_STATUS" == "PASS" && -s "$RUN_DIR/clickhouse_ads_account_risk_features_source.tsv" ]]; then
  if ! clickhouse-client --query "TRUNCATE TABLE ${CLICKHOUSE_ADS_TABLE}" > "$RUN_DIR/clickhouse_load_ads.out" 2> "$RUN_DIR/clickhouse_load_ads.err"; then
    CLICKHOUSE_STATUS="FAIL"
  elif ! clickhouse-client --query "INSERT INTO ${CLICKHOUSE_ADS_TABLE} FORMAT TSVWithNames" < "$RUN_DIR/clickhouse_ads_account_risk_features_source.tsv" >> "$RUN_DIR/clickhouse_load_ads.out" 2>> "$RUN_DIR/clickhouse_load_ads.err"; then
    CLICKHOUSE_STATUS="FAIL"
  fi
else
  CLICKHOUSE_STATUS="FAIL"
  echo "Trino ADS source is missing or empty" > "$RUN_DIR/clickhouse_load_ads.err"
fi
if ! clickhouse-client --query "TRUNCATE TABLE ${CLICKHOUSE_EVENTS_TABLE}" > "$RUN_DIR/clickhouse_load_events.out" 2> "$RUN_DIR/clickhouse_load_events.err"; then
  CLICKHOUSE_STATUS="FAIL"
elif ! clickhouse-client --query "INSERT INTO ${CLICKHOUSE_EVENTS_TABLE} FORMAT JSONEachRow" < "$P11V2_SOURCE_RUN_DIR/risk_events_raw.jsonl" >> "$RUN_DIR/clickhouse_load_events.out" 2>> "$RUN_DIR/clickhouse_load_events.err"; then
  CLICKHOUSE_STATUS="FAIL"
fi

run_clickhouse_query "clickhouse_account_risk_topn" "SELECT account_number, total_event_count, debit_count, credit_count, out_amount, counterparty_count, laundering_event_count, cross_bank_event_count, cross_currency_event_count, risk_score_rule FROM ${CLICKHOUSE_ADS_TABLE} ORDER BY risk_score_rule DESC, laundering_event_count DESC, out_amount DESC LIMIT 20" || CLICKHOUSE_STATUS="FAIL"
run_clickhouse_query "clickhouse_risk_score_buckets" "SELECT multiIf(risk_score_rule >= 80, 'CRITICAL', risk_score_rule >= 60, 'HIGH', risk_score_rule >= 30, 'MEDIUM', 'LOW') AS risk_bucket, count() AS account_count, round(avg(risk_score_rule), 4) AS avg_risk_score, sum(out_amount) AS total_out_amount FROM ${CLICKHOUSE_ADS_TABLE} GROUP BY risk_bucket ORDER BY avg_risk_score DESC" || CLICKHOUSE_STATUS="FAIL"
run_clickhouse_query "clickhouse_p11v2_risk_level_distribution" "SELECT risk_level, count() AS event_count, round(avg(risk_score), 4) AS avg_risk_score, sum(amount_paid) AS total_amount_paid FROM ${CLICKHOUSE_EVENTS_TABLE} GROUP BY risk_level ORDER BY avg_risk_score DESC" || CLICKHOUSE_STATUS="FAIL"
run_clickhouse_query "clickhouse_p11v2_payment_format_risk" "SELECT payment_format, payment_currency, count() AS event_count, round(avg(risk_score), 4) AS avg_risk_score, sum(amount_paid) AS total_amount_paid FROM ${CLICKHOUSE_EVENTS_TABLE} GROUP BY payment_format, payment_currency ORDER BY event_count DESC, avg_risk_score DESC LIMIT 30" || CLICKHOUSE_STATUS="FAIL"

CLICKHOUSE_QUERY_PASS_COUNT=$(awk -F '\t' '$2=="PASS" && $3 > 0 {c++} END {print c+0}' "$RUN_DIR/clickhouse_query_status.tsv")
if [[ "$CLICKHOUSE_QUERY_PASS_COUNT" -lt 3 ]]; then
  CLICKHOUSE_STATUS="FAIL"
fi
step "clickhouse_ads_query_validation" "$CLICKHOUSE_STATUS" "$RUN_DIR/clickhouse_query_status.tsv"

if [[ -z "${ELASTICSEARCH_ELASTIC_PASSWORD:-}" ]]; then
  ES_STATUS="FAIL"
  es_status "credentials" "FAIL" "missing" "ELASTICSEARCH_ELASTIC_PASSWORD not provided"
else
  if systemctl is-active --quiet elasticsearch-finance-v2; then
    echo "elasticsearch already active" > "$RUN_DIR/elasticsearch_service.out"
  else
    sudo_run systemctl start elasticsearch-finance-v2 > "$RUN_DIR/elasticsearch_service.out" 2>&1 || true
  fi
  sleep 10
  ES_STATUS="PASS"
  curl -fsS --cacert "$ES_CA" -u "elastic:${ELASTICSEARCH_ELASTIC_PASSWORD}" \
    -X PUT "https://127.0.0.1:9200/${ES_INDEX}" \
    -H 'Content-Type: application/json' \
    -d '{"settings":{"index":{"number_of_replicas":0}}}' \
    > "$RUN_DIR/elasticsearch_create_index.json" 2> "$RUN_DIR/elasticsearch_create_index.err" || true
  curl -fsS --cacert "$ES_CA" -u "elastic:${ELASTICSEARCH_ELASTIC_PASSWORD}" \
    -X PUT "https://127.0.0.1:9200/${ES_INDEX}/_settings" \
    -H 'Content-Type: application/json' \
    -d '{"index":{"number_of_replicas":0}}' \
    > "$RUN_DIR/elasticsearch_index_settings.json" 2> "$RUN_DIR/elasticsearch_index_settings.err" || true

  python3 - "$P11V2_SOURCE_RUN_DIR/risk_events_raw.jsonl" "$RUN_DIR/elasticsearch_bulk.ndjson" "$ES_INDEX" <<'PY'
import json
import sys
from datetime import datetime, timezone

source_path, bulk_path, index_name = sys.argv[1:4]
ingested_at = datetime.now(timezone.utc).isoformat()

def normalize_time(value):
    text = str(value or "").strip()
    for fmt in ("%Y/%m/%d %H:%M", "%Y/%m/%d %H:%M:%S", "%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
        try:
            dt = datetime.strptime(text, fmt).replace(tzinfo=timezone.utc)
            return dt.isoformat().replace("+00:00", "Z")
        except ValueError:
            pass
    return text

with open(source_path, "r", encoding="utf-8") as src, open(bulk_path, "w", encoding="utf-8", newline="\n") as dst:
    for line in src:
        if not line.strip().startswith("{"):
            continue
        doc = json.loads(line)
        doc["event_time_raw"] = doc.get("event_time", "")
        doc["event_time"] = normalize_time(doc.get("event_time", ""))
        doc["scored_at_raw"] = doc.get("scored_at", "")
        doc["scored_at"] = normalize_time(doc.get("scored_at", ""))
        doc["p12v2_ingested_at"] = ingested_at
        doc_id = f"{doc.get('run_id','')}:{doc.get('transaction_id','')}"
        dst.write(json.dumps({"index": {"_index": index_name, "_id": doc_id}}, separators=(",", ":")) + "\n")
        dst.write(json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n")
PY

  if curl -fsS --cacert "$ES_CA" -u "elastic:${ELASTICSEARCH_ELASTIC_PASSWORD}" \
    -X POST "https://127.0.0.1:9200/_bulk" \
    -H 'Content-Type: application/x-ndjson' \
    --data-binary "@$RUN_DIR/elasticsearch_bulk.ndjson" \
    > "$RUN_DIR/elasticsearch_bulk_response.json" 2> "$RUN_DIR/elasticsearch_bulk.err"; then
    ES_BULK_ERROR_COUNT=$(python3 - "$RUN_DIR/elasticsearch_bulk_response.json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    errors = 0
    for item in data.get("items", []):
        action = next(iter(item.values()))
        if int(action.get("status", 0)) >= 300 or "error" in action:
            errors += 1
    print(errors)
except Exception:
    print(1)
PY
)
    if [[ "$ES_BULK_ERROR_COUNT" -eq 0 ]]; then
      es_status "bulk_import" "PASS" "$RUN_DIR/elasticsearch_bulk.ndjson" "$RUN_DIR/elasticsearch_bulk_response.json"
      if curl -fsS --cacert "$ES_CA" -u "elastic:${ELASTICSEARCH_ELASTIC_PASSWORD}" \
        -X POST "https://127.0.0.1:9200/${ES_INDEX}/_refresh" \
        > "$RUN_DIR/elasticsearch_refresh.json" 2> "$RUN_DIR/elasticsearch_refresh.err"; then
        es_status "refresh" "PASS" "$ES_INDEX" "$RUN_DIR/elasticsearch_refresh.json"
      else
        es_status "refresh" "FAIL" "$ES_INDEX" "$RUN_DIR/elasticsearch_refresh.err"
        ES_STATUS="FAIL"
      fi
    else
      es_status "bulk_import" "FAIL" "$ES_BULK_ERROR_COUNT" "$RUN_DIR/elasticsearch_bulk_response.json"
      ES_STATUS="FAIL"
    fi
  else
    es_status "bulk_import" "FAIL" "$RUN_DIR/elasticsearch_bulk.ndjson" "$RUN_DIR/elasticsearch_bulk.err"
    ES_STATUS="FAIL"
  fi

  curl -fsS --cacert "$ES_CA" -u "elastic:${ELASTICSEARCH_ELASTIC_PASSWORD}" \
    "https://127.0.0.1:9200/_cluster/health/${ES_INDEX}?timeout=30s" \
    > "$RUN_DIR/elasticsearch_health.json" 2> "$RUN_DIR/elasticsearch_health.err" || ES_STATUS="FAIL"
  curl -fsS --cacert "$ES_CA" -u "elastic:${ELASTICSEARCH_ELASTIC_PASSWORD}" \
    "https://127.0.0.1:9200/${ES_INDEX}/_count" \
    > "$RUN_DIR/elasticsearch_count.json" 2> "$RUN_DIR/elasticsearch_count.err" || ES_STATUS="FAIL"
  curl -fsS --cacert "$ES_CA" -u "elastic:${ELASTICSEARCH_ELASTIC_PASSWORD}" \
    -X POST "https://127.0.0.1:9200/${ES_INDEX}/_search" \
    -H 'Content-Type: application/json' \
    -d '{"size":5,"query":{"bool":{"filter":[{"terms":{"risk_level":["HIGH","CRITICAL"]}}]}},"sort":[{"risk_score":{"order":"desc"}}]}' \
    > "$RUN_DIR/elasticsearch_search_sample.json" 2> "$RUN_DIR/elasticsearch_search_sample.err" || ES_STATUS="FAIL"

  ES_HEALTH_STATUS=$(python3 - "$RUN_DIR/elasticsearch_health.json" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("status", ""))
except Exception:
    print("")
PY
)
  ES_DOC_COUNT=$(python3 - "$RUN_DIR/elasticsearch_count.json" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("count", 0))
except Exception:
    print(0)
PY
)
  ES_SEARCH_HITS=$(python3 - "$RUN_DIR/elasticsearch_search_sample.json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    hits = data.get("hits", {}).get("hits", [])
    print(len(hits))
except Exception:
    print(0)
PY
)
  if [[ "$ES_HEALTH_STATUS" == "green" || "$ES_HEALTH_STATUS" == "yellow" ]]; then
    es_status "health" "PASS" "$ES_HEALTH_STATUS" "$RUN_DIR/elasticsearch_health.json"
  else
    es_status "health" "FAIL" "${ES_HEALTH_STATUS:-missing}" "$RUN_DIR/elasticsearch_health.json"
    ES_STATUS="FAIL"
  fi
  if [[ "$ES_DOC_COUNT" -gt 0 ]]; then
    es_status "document_count" "PASS" "$ES_DOC_COUNT" "$RUN_DIR/elasticsearch_count.json"
  else
    es_status "document_count" "FAIL" "$ES_DOC_COUNT" "$RUN_DIR/elasticsearch_count.json"
    ES_STATUS="FAIL"
  fi
  if [[ "$ES_SEARCH_HITS" -gt 0 ]]; then
    es_status "search_sample" "PASS" "$ES_SEARCH_HITS" "$RUN_DIR/elasticsearch_search_sample.json"
  else
    es_status "search_sample" "FAIL" "$ES_SEARCH_HITS" "$RUN_DIR/elasticsearch_search_sample.json"
    ES_STATUS="FAIL"
  fi
fi
step "elasticsearch_investigation_validation" "$ES_STATUS" "$RUN_DIR/elasticsearch_index_status.tsv"

stop_temp_trino

/export/server/flink/bin/flink list -r > "$RUN_DIR/flink_jobs_after.txt" 2>&1 || true
if grep -q 'No running jobs' "$RUN_DIR/flink_jobs_after.txt"; then
  FLINK_POST_STATUS="PASS"
else
  FLINK_POST_STATUS="FAIL"
fi
timeout 20s yarn application -list -appStates RUNNING > "$RUN_DIR/yarn_running_apps_after.out" 2>&1 || true
if grep -q 'Total number of applications.*:0' "$RUN_DIR/yarn_running_apps_after.out"; then
  YARN_POST_STATUS="PASS"
else
  YARN_POST_STATUS="FAIL"
fi
echo -e "component\tstatus\tdetail" > "$RUN_DIR/postcheck.tsv"
echo -e "flink_running_jobs\t$FLINK_POST_STATUS\tsee flink_jobs_after.txt" >> "$RUN_DIR/postcheck.tsv"
echo -e "yarn_running_apps\t$YARN_POST_STATUS\tsee yarn_running_apps_after.out" >> "$RUN_DIR/postcheck.tsv"
step "postcheck" "$([[ "$FLINK_POST_STATUS" == "PASS" && "$YARN_POST_STATUS" == "PASS" ]] && echo PASS || echo FAIL)" "$RUN_DIR/postcheck.tsv"

P12V2_STATUS="PASS"
if [[ "$P11V2_SOURCE_STATUS" != "PASS" || "$TRINO_STATUS" != "PASS" || "$CLICKHOUSE_STATUS" != "PASS" || "$ES_STATUS" != "PASS" || "$FLINK_POST_STATUS" != "PASS" || "$YARN_POST_STATUS" != "PASS" ]]; then
  P12V2_STATUS="FAIL"
fi
if grep -q $'\tFAIL\t' "$RUN_DIR/component_status.tsv"; then
  P12V2_STATUS="FAIL"
fi

echo -e "metric\tvalue" > "$RUN_DIR/p12v2_status.tsv"
echo -e "run_name\t$RUN_NAME" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "run_dir\t$RUN_DIR" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "p11v2_source_run_dir\t$P11V2_SOURCE_RUN_DIR" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "p11v2_source_status\t$P11V2_SOURCE_STATUS" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "trino_status\t$TRINO_STATUS" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "clickhouse_status\t$CLICKHOUSE_STATUS" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "clickhouse_query_pass_count\t$CLICKHOUSE_QUERY_PASS_COUNT" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "elasticsearch_status\t$ES_STATUS" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "elasticsearch_health\t${ES_HEALTH_STATUS:-}" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "elasticsearch_document_count\t${ES_DOC_COUNT:-0}" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "flink_post_status\t$FLINK_POST_STATUS" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "yarn_post_status\t$YARN_POST_STATUS" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "p12v2_status\t$P12V2_STATUS" >> "$RUN_DIR/p12v2_status.tsv"

cat > "$RUN_DIR/p12v2_summary.md" <<MD
# P12v2 Query Investigation Summary

- Run name: \`$RUN_NAME\`
- Run dir: \`$RUN_DIR\`
- P11v2 source: \`$P11V2_SOURCE_RUN_DIR\`
- Trino status: \`$TRINO_STATUS\`
- ClickHouse status: \`$CLICKHOUSE_STATUS\`
- ClickHouse query pass count: \`$CLICKHOUSE_QUERY_PASS_COUNT\`
- Elasticsearch status: \`$ES_STATUS\`
- Elasticsearch health: \`${ES_HEALTH_STATUS:-}\`
- Elasticsearch document count: \`${ES_DOC_COUNT:-0}\`
- Flink postcheck: \`$FLINK_POST_STATUS\`
- YARN postcheck: \`$YARN_POST_STATUS\`
- Status: \`$P12V2_STATUS\`

## Boundary

P12v2 validates Trino, ClickHouse, and Elasticsearch consumption of accepted evidence. It does not rerun P11v2, does not start Doris, does not use OpenSearch, and does not treat ClickHouse or Elasticsearch as the fact source.
MD

echo "P12V2_RUN_DIR=$RUN_DIR"
echo "P12V2_STATUS=$P12V2_STATUS"
cat "$RUN_DIR/p12v2_status.tsv"

if [[ "$P12V2_STATUS" != "PASS" ]]; then
  exit 2
fi
