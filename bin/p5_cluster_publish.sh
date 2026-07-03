#!/usr/bin/env bash
# Purpose: P5 集群发布入口，把本地 P3/P4 Parquet 发布为 finance_bigdata Iceberg 表。
# Boundary: 仅发布金融命名空间，不触碰外部项目数据库、topic、Redis key 或证据。
set -euo pipefail

REMOTE_ROOT=${REMOTE_ROOT:-/home/common/tmp/finance_bigdata_project}
LOCAL_STAGE=${LOCAL_STAGE:-$REMOTE_ROOT/stage/p5_input}
HDFS_ROOT=${HDFS_ROOT:-/lakehouse/projects/finance_bigdata}
RUN_STAMP=$(date +%Y%m%d_%H%M%S)
RUN_NAME="p5_hive_iceberg_publish_${RUN_STAMP}"
RUN_DIR="$REMOTE_ROOT/runs/$RUN_NAME"
HDFS_STAGE="$HDFS_ROOT/stage/p5_input/$RUN_NAME"
HDFS_RUN="$HDFS_ROOT/runs/$RUN_NAME"

export JAVA_HOME=/export/server/jdk17
export PATH=/export/server/spark/bin:/export/server/hadoop/bin:/export/server/hadoop/sbin:$JAVA_HOME/bin:$PATH

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

TABLE_FILES=(
  dwd_finance_transactions.parquet
  dwd_finance_accounts.parquet
  dwd_finance_transaction_events.parquet
  dws_minute_transaction_kpi.parquet
  dws_account_risk_features.parquet
  dws_payment_format_kpi.parquet
  dws_large_transaction_candidates.parquet
)

mkdir -p "$RUN_DIR"

echo "===== p5 prepare hdfs dirs ====="
hdfs dfs -mkdir -p "$HDFS_STAGE" "$HDFS_RUN"

echo "===== p5 validate local stage files ====="
for file_name in "${TABLE_FILES[@]}"; do
  test -s "$LOCAL_STAGE/$file_name"
  ls -lh "$LOCAL_STAGE/$file_name"
done

echo "===== p5 upload parquet to hdfs ====="
for file_name in "${TABLE_FILES[@]}"; do
  hdfs dfs -put -f "$LOCAL_STAGE/$file_name" "$HDFS_STAGE/$file_name"
done
hdfs dfs -ls -h "$HDFS_STAGE" | tee "$RUN_DIR/hdfs_stage_inventory.txt"

cat > "$RUN_DIR/p5_publish.sql" <<SQL
CREATE NAMESPACE IF NOT EXISTS lakehouse.finance_bigdata;

DROP TABLE IF EXISTS lakehouse.finance_bigdata.dwd_finance_transactions;
CREATE TABLE lakehouse.finance_bigdata.dwd_finance_transactions USING iceberg AS
SELECT * FROM parquet.\`hdfs://$HDFS_STAGE/dwd_finance_transactions.parquet\`;

DROP TABLE IF EXISTS lakehouse.finance_bigdata.dwd_finance_accounts;
CREATE TABLE lakehouse.finance_bigdata.dwd_finance_accounts USING iceberg AS
SELECT * FROM parquet.\`hdfs://$HDFS_STAGE/dwd_finance_accounts.parquet\`;

DROP TABLE IF EXISTS lakehouse.finance_bigdata.dwd_finance_transaction_events;
CREATE TABLE lakehouse.finance_bigdata.dwd_finance_transaction_events USING iceberg AS
SELECT * FROM parquet.\`hdfs://$HDFS_STAGE/dwd_finance_transaction_events.parquet\`;

DROP TABLE IF EXISTS lakehouse.finance_bigdata.dws_minute_transaction_kpi;
CREATE TABLE lakehouse.finance_bigdata.dws_minute_transaction_kpi USING iceberg AS
SELECT * FROM parquet.\`hdfs://$HDFS_STAGE/dws_minute_transaction_kpi.parquet\`;

DROP TABLE IF EXISTS lakehouse.finance_bigdata.dws_account_risk_features;
CREATE TABLE lakehouse.finance_bigdata.dws_account_risk_features USING iceberg AS
SELECT * FROM parquet.\`hdfs://$HDFS_STAGE/dws_account_risk_features.parquet\`;

DROP TABLE IF EXISTS lakehouse.finance_bigdata.dws_payment_format_kpi;
CREATE TABLE lakehouse.finance_bigdata.dws_payment_format_kpi USING iceberg AS
SELECT * FROM parquet.\`hdfs://$HDFS_STAGE/dws_payment_format_kpi.parquet\`;

DROP TABLE IF EXISTS lakehouse.finance_bigdata.dws_large_transaction_candidates;
CREATE TABLE lakehouse.finance_bigdata.dws_large_transaction_candidates USING iceberg AS
SELECT * FROM parquet.\`hdfs://$HDFS_STAGE/dws_large_transaction_candidates.parquet\`;
SQL

echo "===== p5 spark publish ====="
spark-sql "${SPARK_ARGS[@]}" -f "$RUN_DIR/p5_publish.sql" > "$RUN_DIR/spark_sql_publish.out" 2>&1

cat > "$RUN_DIR/p5_validate.sql" <<SQL
SHOW NAMESPACES IN lakehouse;
SHOW TABLES IN lakehouse.finance_bigdata;
SELECT 'dwd_finance_transactions' AS table_name, COUNT(*) AS row_count FROM lakehouse.finance_bigdata.dwd_finance_transactions
UNION ALL SELECT 'dwd_finance_accounts', COUNT(*) FROM lakehouse.finance_bigdata.dwd_finance_accounts
UNION ALL SELECT 'dwd_finance_transaction_events', COUNT(*) FROM lakehouse.finance_bigdata.dwd_finance_transaction_events
UNION ALL SELECT 'dws_minute_transaction_kpi', COUNT(*) FROM lakehouse.finance_bigdata.dws_minute_transaction_kpi
UNION ALL SELECT 'dws_account_risk_features', COUNT(*) FROM lakehouse.finance_bigdata.dws_account_risk_features
UNION ALL SELECT 'dws_payment_format_kpi', COUNT(*) FROM lakehouse.finance_bigdata.dws_payment_format_kpi
UNION ALL SELECT 'dws_large_transaction_candidates', COUNT(*) FROM lakehouse.finance_bigdata.dws_large_transaction_candidates;
SQL

echo "===== p5 spark validation ====="
spark-sql "${SPARK_ARGS[@]}" -f "$RUN_DIR/p5_validate.sql" > "$RUN_DIR/spark_sql_validate.out" 2>&1

cat > "$RUN_DIR/expected_counts.tsv" <<'TSV'
table_name	expected_count
dwd_finance_transactions	5078345
dwd_finance_accounts	518581
dwd_finance_transaction_events	10156690
dws_minute_transaction_kpi	88316
dws_account_risk_features	515080
dws_payment_format_kpi	7
dws_large_transaction_candidates	200403
TSV

run_count() {
  local table_name="$1"
  spark-sql "${SPARK_ARGS[@]}" -S -e "SELECT COUNT(*) FROM lakehouse.finance_bigdata.${table_name};" 2>/dev/null | awk '/^[0-9]+$/ {v=$1} END {print v}'
}

echo -e "table_name\texpected_count\tactual_count\tstatus" > "$RUN_DIR/count_validation.tsv"
while IFS=$'\t' read -r table_name expected_count; do
  if [[ "$table_name" == "table_name" ]]; then
    continue
  fi
  actual_count=$(run_count "$table_name")
  if [[ "$actual_count" == "$expected_count" ]]; then
    status="PASS"
  else
    status="FAIL"
  fi
  echo -e "${table_name}\t${expected_count}\t${actual_count}\t${status}" >> "$RUN_DIR/count_validation.tsv"
done < "$RUN_DIR/expected_counts.tsv"

if grep -q $'\tFAIL$' "$RUN_DIR/count_validation.tsv"; then
  overall_status="FAIL"
else
  overall_status="PASS"
fi

echo "===== p5 hive metastore visibility ====="
timeout 45s /export/server/hive/bin/beeline -u "jdbc:hive2://hadoop1:10000/default" -n common -e "SHOW DATABASES LIKE 'finance_bigdata';" > "$RUN_DIR/beeline_show_database.out" 2>&1 || true

cat > "$RUN_DIR/p5_summary.md" <<MD
# P5 Hive/Iceberg Publish Summary

- Run name: \`$RUN_NAME\`
- Run dir: \`$RUN_DIR\`
- HDFS stage: \`$HDFS_STAGE\`
- HDFS run: \`$HDFS_RUN\`
- Spark catalog: \`lakehouse\`
- Namespace/database: \`finance_bigdata\`
- Status: \`$overall_status\`

## Validation

See \`count_validation.tsv\`.
MD

cat > "$RUN_DIR/steps.tsv" <<TSV
step	status	detail
prepare_hdfs_dirs	PASS	$HDFS_STAGE
upload_parquet_to_hdfs	PASS	$HDFS_STAGE
spark_publish	PASS	$RUN_DIR/spark_sql_publish.out
spark_validate	PASS	$RUN_DIR/spark_sql_validate.out
count_validation	$overall_status	$RUN_DIR/count_validation.tsv
beeline_visibility	INFO	$RUN_DIR/beeline_show_database.out
TSV

hdfs dfs -put -f "$RUN_DIR"/count_validation.tsv "$HDFS_RUN/count_validation.tsv"
hdfs dfs -put -f "$RUN_DIR"/p5_summary.md "$HDFS_RUN/p5_summary.md"
hdfs dfs -put -f "$RUN_DIR"/steps.tsv "$HDFS_RUN/steps.tsv"

cat "$RUN_DIR/count_validation.tsv"
echo "P5_RUN_DIR=$RUN_DIR"
echo "P5_HDFS_RUN=$HDFS_RUN"
echo "P5_STATUS=$overall_status"
if [[ "$overall_status" != "PASS" ]]; then
  exit 2
fi
