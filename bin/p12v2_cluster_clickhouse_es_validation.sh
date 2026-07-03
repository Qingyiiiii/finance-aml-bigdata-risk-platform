#!/usr/bin/env bash
set -euo pipefail

REMOTE_ROOT=${REMOTE_ROOT:-/home/common/tmp/finance_bigdata_project}
RUN_STAMP=$(date +%Y%m%d_%H%M%S)
RUN_NAME="p12v2_clickhouse_es_validation_${RUN_STAMP}"
RUN_DIR="$REMOTE_ROOT/runs/$RUN_NAME"
P11V2_SOURCE_RUN_DIR=${P11V2_SOURCE_RUN_DIR:-}
CLICKHOUSE_DB=${CLICKHOUSE_DB:-finance_bigdata_v2}
CLICKHOUSE_ADS_TABLE=${CLICKHOUSE_ADS_TABLE:-finance_bigdata_v2.ads_account_risk_features}
CLICKHOUSE_EVENTS_TABLE=${CLICKHOUSE_EVENTS_TABLE:-finance_bigdata_v2.ads_p11v2_risk_events}
ES_INDEX=${ES_INDEX:-finance-risk-events-v2}
ES_CA=${ES_CA:-/export/server/elasticsearch/config/certs/ca/ca.crt}

mkdir -p "$RUN_DIR/sql"
echo "P12V2_RUN_DIR=$RUN_DIR"

CREDENTIALS_FILE="$(mktemp /tmp/finance_p12v2_ch_es_credentials.XXXXXX)"
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
echo -e "query\tstatus\trows\tdetail" > "$RUN_DIR/clickhouse_query_status.tsv"
echo -e "query_name\trow_number\trow_json" > "$RUN_DIR/clickhouse_query_results.tsv"
echo -e "item\tstatus\tvalue\tdetail" > "$RUN_DIR/elasticsearch_index_status.tsv"
: > "$RUN_DIR/elasticsearch_search_sample.json"
: > "$RUN_DIR/elasticsearch_health.json"
: > "$RUN_DIR/elasticsearch_count.json"
: > "$RUN_DIR/elasticsearch_bulk_response.json"
: > "$RUN_DIR/elasticsearch_refresh.json"

step() {
  echo -e "$1\t$2\t$3" >> "$RUN_DIR/p12v2_steps.tsv"
}

component() {
  echo -e "$1\t$2\t$3" >> "$RUN_DIR/component_status.tsv"
}

source_metric() {
  echo -e "$1\t$2\t$3\t$4" >> "$RUN_DIR/p11v2_source_reference.tsv"
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

row_count_from_tsv() {
  local file_path="$1"
  awk 'END {print (NR > 0 ? NR - 1 : 0)}' "$file_path"
}

run_clickhouse_query() {
  local name="$1"
  local sql_text="$2"
  local output_file="$RUN_DIR/${name}.tsv"
  local err_file="$RUN_DIR/${name}.err"
  printf "%s\n" "$sql_text" > "$RUN_DIR/sql/${name}.sql"
  if clickhouse-client --query "$sql_text FORMAT TSVWithNames" > "$output_file" 2> "$err_file"; then
    local rows
    rows=$(row_count_from_tsv "$output_file")
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

if [[ -z "$P11V2_SOURCE_RUN_DIR" ]]; then
  P11V2_SOURCE_RUN_DIR="$(find_latest_p11v2_run || true)"
fi

if [[ -z "$P11V2_SOURCE_RUN_DIR" || ! -s "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv" || ! -s "$P11V2_SOURCE_RUN_DIR/risk_events_raw.jsonl" ]]; then
  source_metric "p11v2_source_run_dir" "${P11V2_SOURCE_RUN_DIR:-MISSING}" "FAIL" "required P11v2 files missing"
  echo "P11v2 accepted evidence not found" >&2
  exit 2
fi

P11V2_RAW_EVENTS=$(awk -F '\t' '$1=="raw_event_count" {print $2}' "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv")
P11V2_VALID_EVENTS=$(awk -F '\t' '$1=="schema_valid_event_count" {print $2}' "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv")
P11V2_INVALID_EVENTS=$(awk -F '\t' '$1=="schema_invalid_event_count" {print $2}' "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv")
P11V2_HBASE_ROWS=$(awk -F '\t' '$1=="hbase_rows_written" {print $2}' "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv")
P11V2_CONSISTENCY_FAILS=$(awk -F '\t' '$1=="redis_hbase_consistency_fail_count" {print $2}' "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv")
P11V2_RAW_EVENTS=${P11V2_RAW_EVENTS:-0}
P11V2_VALID_EVENTS=${P11V2_VALID_EVENTS:-0}
P11V2_INVALID_EVENTS=${P11V2_INVALID_EVENTS:-1}
P11V2_HBASE_ROWS=${P11V2_HBASE_ROWS:-0}
P11V2_CONSISTENCY_FAILS=${P11V2_CONSISTENCY_FAILS:-1}

P11V2_SOURCE_STATUS="PASS"
if [[ "$P11V2_RAW_EVENTS" -le 0 || "$P11V2_VALID_EVENTS" -le 0 || "$P11V2_INVALID_EVENTS" -ne 0 || "$P11V2_HBASE_ROWS" -le 0 || "$P11V2_CONSISTENCY_FAILS" -ne 0 ]]; then
  P11V2_SOURCE_STATUS="FAIL"
fi
source_metric "p11v2_source_run_dir" "$P11V2_SOURCE_RUN_DIR" "$P11V2_SOURCE_STATUS" "locked source"
source_metric "p11v2_raw_event_count" "$P11V2_RAW_EVENTS" "$P11V2_SOURCE_STATUS" "$P11V2_SOURCE_RUN_DIR/risk_events_raw.jsonl"
source_metric "p11v2_schema_valid_event_count" "$P11V2_VALID_EVENTS" "$P11V2_SOURCE_STATUS" "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv"
source_metric "p11v2_schema_invalid_event_count" "$P11V2_INVALID_EVENTS" "$P11V2_SOURCE_STATUS" "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv"
source_metric "p11v2_hbase_rows_written" "$P11V2_HBASE_ROWS" "$P11V2_SOURCE_STATUS" "$P11V2_SOURCE_RUN_DIR/hbase_readback_sample.tsv"
source_metric "p11v2_redis_hbase_consistency_fail_count" "$P11V2_CONSISTENCY_FAILS" "$P11V2_SOURCE_STATUS" "$P11V2_SOURCE_RUN_DIR/p11v2_state_summary.tsv"
step "lock_p11v2_source" "$P11V2_SOURCE_STATUS" "$P11V2_SOURCE_RUN_DIR"

source /etc/profile.d/bigdata.sh 2>/dev/null || true
export JAVA_HOME=${JAVA_HOME:-/export/server/jdk25}
export PATH=$JAVA_HOME/bin:/export/server/hadoop/bin:/export/server/hadoop/sbin:$PATH

CLICKHOUSE_STATUS="PASS"
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
  CLICKHOUSE_STATUS="FAIL"
fi

if clickhouse-client --query "CREATE DATABASE IF NOT EXISTS ${CLICKHOUSE_DB}" > "$RUN_DIR/clickhouse_database.out" 2> "$RUN_DIR/clickhouse_database.err" \
  && clickhouse-client --query "EXISTS DATABASE ${CLICKHOUSE_DB}" >> "$RUN_DIR/clickhouse_database.out" 2>> "$RUN_DIR/clickhouse_database.err"; then
  component "clickhouse_database" "PASS" "$CLICKHOUSE_DB"
else
  component "clickhouse_database" "FAIL" "$RUN_DIR/clickhouse_database.err"
  CLICKHOUSE_STATUS="FAIL"
fi

if clickhouse-client --query "
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
ORDER BY (account_number, risk_score_rule);
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
ORDER BY (run_id, event_account, transaction_id)" > "$RUN_DIR/clickhouse_tables.out" 2> "$RUN_DIR/clickhouse_tables.err"; then
  component "clickhouse_tables" "PASS" "${CLICKHOUSE_ADS_TABLE},${CLICKHOUSE_EVENTS_TABLE}"
else
  component "clickhouse_tables" "FAIL" "$RUN_DIR/clickhouse_tables.err"
  CLICKHOUSE_STATUS="FAIL"
fi

python3 - "$P11V2_SOURCE_RUN_DIR/risk_events_raw.jsonl" "$RUN_DIR/clickhouse_ads_from_p11v2.tsv" "$RUN_DIR/clickhouse_ads_generation.tsv" <<'PY'
import csv
import json
import sys
from collections import defaultdict
from datetime import datetime
from decimal import Decimal

source_path, ads_path, stats_path = sys.argv[1:4]
now_text = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
accounts = {}
event_count = 0

def new_account():
    return {
        "total_event_count": 0,
        "debit_count": 0,
        "credit_count": 0,
        "out_amount": Decimal("0"),
        "counterparties": set(),
        "laundering_event_count": 0,
        "cross_bank_event_count": 0,
        "cross_currency_event_count": 0,
        "risk_score_rule": 0.0,
    }

for line in open(source_path, encoding="utf-8"):
    line = line.strip()
    if not line or not line.startswith("{"):
        continue
    doc = json.loads(line)
    account = str(doc.get("event_account") or "").strip()
    if not account:
        continue
    event_count += 1
    row = accounts.setdefault(account, new_account())
    row["total_event_count"] += 1
    row["debit_count"] += 1
    amount = Decimal(str(doc.get("amount_paid") or "0"))
    row["out_amount"] += amount
    counterparty = str(doc.get("counterparty_account") or "").strip()
    if counterparty:
        row["counterparties"].add(counterparty)
    risk_score = float(doc.get("risk_score") or 0)
    row["risk_score_rule"] = max(row["risk_score_rule"], risk_score)
    risk_level = str(doc.get("risk_level") or "")
    if risk_level in {"HIGH", "CRITICAL"} or risk_score >= 60:
        row["laundering_event_count"] += 1
    reason_text = f"{doc.get('risk_reasons') or ''};{doc.get('rule_hits') or ''}"
    if "CROSS_BANK" in reason_text:
        row["cross_bank_event_count"] += 1
    if "CROSS_CURRENCY" in reason_text or str(doc.get("payment_currency") or "") not in {"", "Yuan"}:
        row["cross_currency_event_count"] += 1

fieldnames = [
    "account_number",
    "total_event_count",
    "debit_count",
    "credit_count",
    "out_amount",
    "counterparty_count",
    "laundering_event_count",
    "cross_bank_event_count",
    "cross_currency_event_count",
    "risk_score_rule",
    "updated_at",
]
with open(ads_path, "w", encoding="utf-8", newline="") as out:
    writer = csv.DictWriter(out, fieldnames=fieldnames, delimiter="\t", lineterminator="\n")
    writer.writeheader()
    for account, row in sorted(accounts.items(), key=lambda item: (-item[1]["risk_score_rule"], -item[1]["laundering_event_count"], item[0])):
        writer.writerow({
            "account_number": account,
            "total_event_count": row["total_event_count"],
            "debit_count": row["debit_count"],
            "credit_count": row["credit_count"],
            "out_amount": f"{row['out_amount']:.2f}",
            "counterparty_count": len(row["counterparties"]),
            "laundering_event_count": row["laundering_event_count"],
            "cross_bank_event_count": row["cross_bank_event_count"],
            "cross_currency_event_count": row["cross_currency_event_count"],
            "risk_score_rule": f"{row['risk_score_rule']:.4f}",
            "updated_at": now_text,
        })
with open(stats_path, "w", encoding="utf-8", newline="") as stats:
    stats.write("metric\tvalue\n")
    stats.write(f"source_event_count\t{event_count}\n")
    stats.write(f"ads_account_count\t{len(accounts)}\n")
PY

if ! clickhouse-client --query "TRUNCATE TABLE ${CLICKHOUSE_ADS_TABLE}" > "$RUN_DIR/clickhouse_load_ads.out" 2> "$RUN_DIR/clickhouse_load_ads.err"; then
  CLICKHOUSE_STATUS="FAIL"
elif ! clickhouse-client --query "INSERT INTO ${CLICKHOUSE_ADS_TABLE} FORMAT TSVWithNames" < "$RUN_DIR/clickhouse_ads_from_p11v2.tsv" >> "$RUN_DIR/clickhouse_load_ads.out" 2>> "$RUN_DIR/clickhouse_load_ads.err"; then
  CLICKHOUSE_STATUS="FAIL"
fi

if ! clickhouse-client --query "TRUNCATE TABLE ${CLICKHOUSE_EVENTS_TABLE}" > "$RUN_DIR/clickhouse_load_events.out" 2> "$RUN_DIR/clickhouse_load_events.err"; then
  CLICKHOUSE_STATUS="FAIL"
elif ! clickhouse-client --query "INSERT INTO ${CLICKHOUSE_EVENTS_TABLE} FORMAT JSONEachRow" < "$P11V2_SOURCE_RUN_DIR/risk_events_raw.jsonl" >> "$RUN_DIR/clickhouse_load_events.out" 2>> "$RUN_DIR/clickhouse_load_events.err"; then
  CLICKHOUSE_STATUS="FAIL"
fi

run_clickhouse_query "clickhouse_ads_table_count" "SELECT count() AS ads_account_rows FROM ${CLICKHOUSE_ADS_TABLE}" || CLICKHOUSE_STATUS="FAIL"
run_clickhouse_query "clickhouse_events_table_count" "SELECT count() AS risk_event_rows FROM ${CLICKHOUSE_EVENTS_TABLE}" || CLICKHOUSE_STATUS="FAIL"
run_clickhouse_query "clickhouse_high_risk_account_topn" "SELECT account_number, total_event_count, counterparty_count, laundering_event_count, cross_bank_event_count, cross_currency_event_count, out_amount, risk_score_rule FROM ${CLICKHOUSE_ADS_TABLE} WHERE risk_score_rule >= 60 OR laundering_event_count > 0 ORDER BY risk_score_rule DESC, laundering_event_count DESC, out_amount DESC LIMIT 20" || CLICKHOUSE_STATUS="FAIL"
run_clickhouse_query "clickhouse_risk_level_distribution" "SELECT risk_level, count() AS event_count, round(avg(risk_score), 4) AS avg_risk_score, sum(amount_paid) AS total_amount_paid FROM ${CLICKHOUSE_EVENTS_TABLE} GROUP BY risk_level ORDER BY avg_risk_score DESC" || CLICKHOUSE_STATUS="FAIL"
run_clickhouse_query "clickhouse_payment_currency_risk_aggregation" "SELECT payment_format, payment_currency, count() AS event_count, round(avg(risk_score), 4) AS avg_risk_score, sum(amount_paid) AS total_amount_paid FROM ${CLICKHOUSE_EVENTS_TABLE} GROUP BY payment_format, payment_currency ORDER BY event_count DESC, avg_risk_score DESC LIMIT 30" || CLICKHOUSE_STATUS="FAIL"
run_clickhouse_query "clickhouse_risk_score_buckets" "SELECT multiIf(risk_score >= 80, 'CRITICAL', risk_score >= 60, 'HIGH', risk_score >= 30, 'MEDIUM', 'LOW') AS risk_bucket, count() AS event_count, round(avg(risk_score), 4) AS avg_risk_score FROM ${CLICKHOUSE_EVENTS_TABLE} GROUP BY risk_bucket ORDER BY avg_risk_score DESC" || CLICKHOUSE_STATUS="FAIL"

python3 - "$RUN_DIR/clickhouse_query_results.tsv" \
  "clickhouse_high_risk_account_topn=$RUN_DIR/clickhouse_high_risk_account_topn.tsv" \
  "clickhouse_risk_level_distribution=$RUN_DIR/clickhouse_risk_level_distribution.tsv" \
  "clickhouse_payment_currency_risk_aggregation=$RUN_DIR/clickhouse_payment_currency_risk_aggregation.tsv" \
  "clickhouse_risk_score_buckets=$RUN_DIR/clickhouse_risk_score_buckets.tsv" <<'PY'
import csv
import json
import sys

out_path = sys.argv[1]
with open(out_path, "w", encoding="utf-8", newline="") as out:
    writer = csv.writer(out, delimiter="\t", lineterminator="\n")
    writer.writerow(["query_name", "row_number", "row_json"])
    for spec in sys.argv[2:]:
        name, path = spec.split("=", 1)
        with open(path, encoding="utf-8", newline="") as source:
            reader = csv.DictReader(source, delimiter="\t")
            for index, row in enumerate(reader, start=1):
                writer.writerow([name, index, json.dumps(row, ensure_ascii=False, separators=(",", ":"))])
PY

CLICKHOUSE_QUERY_PASS_COUNT=$(awk -F '\t' '$1 ~ /^clickhouse_(high_risk_account_topn|risk_level_distribution|payment_currency_risk_aggregation)$/ && $2=="PASS" && $3 > 0 {c++} END {print c+0}' "$RUN_DIR/clickhouse_query_status.tsv")
if [[ "$CLICKHOUSE_QUERY_PASS_COUNT" -lt 3 ]]; then
  CLICKHOUSE_STATUS="FAIL"
fi
step "clickhouse_validation" "$CLICKHOUSE_STATUS" "$RUN_DIR/clickhouse_query_status.tsv"

ES_STATUS="PASS"
ES_HEALTH_STATUS=""
ES_DOC_COUNT=0
ES_SEARCH_HITS=0
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
    for fmt in ("%Y/%m/%d %H:%M", "%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(text, fmt).replace(tzinfo=timezone.utc).isoformat().replace("+00:00", "Z")
        except ValueError:
            pass
    return text

with open(source_path, "r", encoding="utf-8") as src, open(bulk_path, "w", encoding="utf-8", newline="\n") as dst:
    for line in src:
        if not line.strip().startswith("{"):
            continue
        doc = json.loads(line)
        doc["event_time_raw"] = doc.get("event_time", "")
        doc["scored_at_raw"] = doc.get("scored_at", "")
        doc["event_time"] = normalize_time(doc.get("event_time"))
        doc["scored_at"] = normalize_time(doc.get("scored_at"))
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
    -d '{"size":5,"_source":["run_id","transaction_id","event_account","risk_level","risk_score","payment_currency","payment_format","amount_paid"],"query":{"bool":{"should":[{"match":{"risk_level":"CRITICAL"}},{"match":{"risk_level":"HIGH"}}],"minimum_should_match":1}},"sort":[{"risk_score":{"order":"desc"}}]}' \
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
    print(len(data.get("hits", {}).get("hits", [])))
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
step "elasticsearch_validation" "$ES_STATUS" "$RUN_DIR/elasticsearch_index_status.tsv"

/export/server/flink/bin/flink list -r > "$RUN_DIR/flink_jobs_after.txt" 2>&1 || true
yarn application -list -appStates RUNNING > "$RUN_DIR/yarn_running_apps_after.out" 2>&1 || true
FLINK_RUNNING_COUNT=$(grep -Ec '^[0-9a-f]{32} :' "$RUN_DIR/flink_jobs_after.txt" || true)
YARN_RUNNING_COUNT=$(awk '/Total number of applications/ {line=$0; sub(/^.*:/, "", line); gsub(/[^0-9]/, "", line); print line}' "$RUN_DIR/yarn_running_apps_after.out" | tail -1)
YARN_RUNNING_COUNT=${YARN_RUNNING_COUNT:-0}
FLINK_POST_STATUS="PASS"
YARN_POST_STATUS="PASS"
if [[ "$FLINK_RUNNING_COUNT" -ne 0 ]]; then
  FLINK_POST_STATUS="FAIL"
fi
if ! [[ "$YARN_RUNNING_COUNT" =~ ^[0-9]+$ ]] || [[ "$YARN_RUNNING_COUNT" -ne 0 ]]; then
  YARN_POST_STATUS="FAIL"
fi
echo -e "component\tstatus\tdetail" > "$RUN_DIR/postcheck.tsv"
echo -e "flink_running_jobs\t$FLINK_POST_STATUS\tcount=$FLINK_RUNNING_COUNT; see flink_jobs_after.txt" >> "$RUN_DIR/postcheck.tsv"
echo -e "yarn_running_apps\t$YARN_POST_STATUS\tcount=$YARN_RUNNING_COUNT; see yarn_running_apps_after.out" >> "$RUN_DIR/postcheck.tsv"
step "postcheck" "$([[ "$FLINK_POST_STATUS" == "PASS" && "$YARN_POST_STATUS" == "PASS" ]] && echo PASS || echo FAIL)" "$RUN_DIR/postcheck.tsv"

ADS_ROWS=$(awk -F '\t' 'NR==2 {print $1}' "$RUN_DIR/clickhouse_ads_table_count.tsv" 2>/dev/null || echo 0)
EVENT_ROWS=$(awk -F '\t' 'NR==2 {print $1}' "$RUN_DIR/clickhouse_events_table_count.tsv" 2>/dev/null || echo 0)
ADS_ROWS=${ADS_ROWS:-0}
EVENT_ROWS=${EVENT_ROWS:-0}

P12V2_STATUS="PASS"
if [[ "$P11V2_SOURCE_STATUS" != "PASS" || "$CLICKHOUSE_STATUS" != "PASS" || "$CLICKHOUSE_QUERY_PASS_COUNT" -lt 3 || "$ES_STATUS" != "PASS" || "$FLINK_POST_STATUS" != "PASS" || "$YARN_POST_STATUS" != "PASS" ]]; then
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
echo -e "clickhouse_database\t$CLICKHOUSE_DB" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "clickhouse_ads_table\t$CLICKHOUSE_ADS_TABLE" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "clickhouse_ads_rows\t$ADS_ROWS" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "clickhouse_events_rows\t$EVENT_ROWS" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "clickhouse_status\t$CLICKHOUSE_STATUS" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "clickhouse_query_pass_count\t$CLICKHOUSE_QUERY_PASS_COUNT" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "elasticsearch_index\t$ES_INDEX" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "elasticsearch_status\t$ES_STATUS" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "elasticsearch_health\t${ES_HEALTH_STATUS:-}" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "elasticsearch_document_count\t${ES_DOC_COUNT:-0}" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "elasticsearch_search_hits\t${ES_SEARCH_HITS:-0}" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "flink_post_status\t$FLINK_POST_STATUS" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "yarn_post_status\t$YARN_POST_STATUS" >> "$RUN_DIR/p12v2_status.tsv"
echo -e "p12v2_status\t$P12V2_STATUS" >> "$RUN_DIR/p12v2_status.tsv"

cat > "$RUN_DIR/p12v2_summary.md" <<MD
# P12v2 ClickHouse and Elasticsearch Validation Summary

- Run name: \`$RUN_NAME\`
- Run dir: \`$RUN_DIR\`
- P11v2 source: \`$P11V2_SOURCE_RUN_DIR\`
- P11v2 source status: \`$P11V2_SOURCE_STATUS\`
- ClickHouse database: \`$CLICKHOUSE_DB\`
- ClickHouse ADS table: \`$CLICKHOUSE_ADS_TABLE\`
- ClickHouse ADS rows: \`$ADS_ROWS\`
- ClickHouse risk event rows: \`$EVENT_ROWS\`
- ClickHouse query pass count: \`$CLICKHOUSE_QUERY_PASS_COUNT\`
- Elasticsearch index: \`$ES_INDEX\`
- Elasticsearch status: \`$ES_STATUS\`
- Elasticsearch health: \`${ES_HEALTH_STATUS:-}\`
- Elasticsearch document count: \`${ES_DOC_COUNT:-0}\`
- Elasticsearch search hits: \`${ES_SEARCH_HITS:-0}\`
- Flink postcheck: \`$FLINK_POST_STATUS\`
- YARN postcheck: \`$YARN_POST_STATUS\`
- Status: \`$P12V2_STATUS\`

## Boundary

This run validates only ClickHouse and Elasticsearch consumption from accepted P11v2 evidence. It does not rerun P11v2, does not start Doris, does not use OpenSearch, does not treat ClickHouse or Elasticsearch as the fact source, does not generate a P13v2 BI package, and does not print Elasticsearch/Ranger/Atlas passwords.
MD

echo "P12V2_RUN_DIR=$RUN_DIR"
echo "P12V2_STATUS=$P12V2_STATUS"
cat "$RUN_DIR/p12v2_status.tsv"

if [[ "$P12V2_STATUS" != "PASS" ]]; then
  exit 2
fi
