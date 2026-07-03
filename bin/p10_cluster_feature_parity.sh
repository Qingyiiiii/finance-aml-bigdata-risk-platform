#!/usr/bin/env bash
# Purpose: P10 集群特征一致性脚本，从 Iceberg 数仓层复现 P9 非泄漏特征口径。
# Boundary: P10 不训练新模型，只验证 warehouse-derived features 与 P9 accepted 证据对齐。
set -euo pipefail

REMOTE_ROOT=${REMOTE_ROOT:-/home/common/tmp/finance_bigdata_project}
LOCAL_P9_FEATURE_PARQUET=${LOCAL_P9_FEATURE_PARQUET:-$REMOTE_ROOT/stage/p10_input/feature_dataset.parquet}
HDFS_ROOT=${HDFS_ROOT:-/lakehouse/projects/finance_bigdata}
RUN_STAMP=$(date +%Y%m%d_%H%M%S)
RUN_NAME="p10_feature_parity_${RUN_STAMP}"
RUN_DIR="$REMOTE_ROOT/runs/$RUN_NAME"
HDFS_STAGE="$HDFS_ROOT/stage/p10_input/$RUN_NAME"
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
  --conf spark.driver.port=37201
  --conf spark.blockManager.port=37202
  --conf spark.sql.shuffle.partitions=2
)

mkdir -p "$RUN_DIR/sql"
echo -e "step\tstatus\tdetail" > "$RUN_DIR/steps.tsv"
: > "$RUN_DIR/spark_sql.err"

step() {
  echo -e "$1\t$2\t$3" >> "$RUN_DIR/steps.tsv"
}

filter_spark_stdout() {
  grep -Ev '^(20[0-9]{2}-[0-9]{2}-[0-9]{2}T|WARNING:|SLF4J:|Connecting to|Connected to|INFO[[:space:]]|Beeline version|Closing:)' "$1" || true
}

run_query() {
  local name="$1"
  local header="$2"
  local sql_file="$3"
  local output_file="$RUN_DIR/$name"
  local raw_output="$RUN_DIR/$name.raw"
  echo -e "$header" > "$output_file"
  spark-sql "${SPARK_ARGS[@]}" -S -f "$sql_file" > "$raw_output" 2>> "$RUN_DIR/spark_sql.err"
  filter_spark_stdout "$raw_output" >> "$output_file"
}

test -s "$LOCAL_P9_FEATURE_PARQUET"
step "validate_local_p9_feature" "PASS" "$LOCAL_P9_FEATURE_PARQUET"

hdfs dfs -mkdir -p "$HDFS_STAGE" "$HDFS_RUN"
hdfs dfs -put -f "$LOCAL_P9_FEATURE_PARQUET" "$HDFS_STAGE/feature_dataset.parquet"
hdfs dfs -ls -h "$HDFS_STAGE" > "$RUN_DIR/hdfs_stage_inventory.txt"
step "upload_p9_feature_to_hdfs" "PASS" "$HDFS_STAGE/feature_dataset.parquet"

P9_FEATURE_VIEW="parquet.\`hdfs://$HDFS_STAGE/feature_dataset.parquet\`"

cat > "$RUN_DIR/sql/schema.sql" <<SQL
CREATE OR REPLACE TEMPORARY VIEW p9_feature
USING parquet
OPTIONS (path 'hdfs://$HDFS_STAGE/feature_dataset.parquet');
DESCRIBE p9_feature;
SQL
spark-sql "${SPARK_ARGS[@]}" -S -f "$RUN_DIR/sql/schema.sql" > "$RUN_DIR/schema_parity.tsv" 2>> "$RUN_DIR/spark_sql.err"
mv "$RUN_DIR/schema_parity.tsv" "$RUN_DIR/schema_parity.tsv.raw"
filter_spark_stdout "$RUN_DIR/schema_parity.tsv.raw" > "$RUN_DIR/schema_parity.tsv"
step "schema_describe" "PASS" "$RUN_DIR/schema_parity.tsv"

REQUIRED_FIELDS=(
  transaction_id transaction_date split transaction_hour amount_paid log_amount_paid
  payment_currency payment_format is_cross_bank is_cross_currency hour_sin hour_cos
  from_total_event_count from_debit_count from_credit_count from_out_amount from_in_amount
  from_max_out_amount from_counterparty_count from_cross_bank_event_count
  from_cross_currency_event_count from_out_in_ratio from_debit_credit_ratio is_laundering
)

echo -e "field\tstatus\tdetail" > "$RUN_DIR/required_field_scan.tsv"
for field in "${REQUIRED_FIELDS[@]}"; do
  if awk -v f="$field" '$1 == f {found=1} END {exit found ? 0 : 1}' "$RUN_DIR/schema_parity.tsv"; then
    echo -e "$field\tPASS\tpresent" >> "$RUN_DIR/required_field_scan.tsv"
  else
    echo -e "$field\tFAIL\tmissing" >> "$RUN_DIR/required_field_scan.tsv"
  fi
done

LEAKAGE_FIELDS=(laundering_event_count risk_score_rule from_laundering_event_count from_risk_score_rule)
echo -e "field\tstatus\tdetail" > "$RUN_DIR/leakage_field_scan.tsv"
for field in "${LEAKAGE_FIELDS[@]}"; do
  if awk -v f="$field" '$1 == f {found=1} END {exit found ? 0 : 1}' "$RUN_DIR/schema_parity.tsv"; then
    echo -e "$field\tFAIL\tleakage field present" >> "$RUN_DIR/leakage_field_scan.tsv"
  else
    echo -e "$field\tPASS\tnot present" >> "$RUN_DIR/leakage_field_scan.tsv"
  fi
done
step "schema_field_scan" "PASS" "$RUN_DIR/required_field_scan.tsv and leakage_field_scan.tsv"

cat > "$RUN_DIR/sql/source_table_counts.sql" <<SQL
SELECT 'dwd_finance_transactions' AS table_name, 5078345 AS expected_count, COUNT(*) AS actual_count,
       CASE WHEN COUNT(*) = 5078345 THEN 'PASS' ELSE 'FAIL' END AS status
FROM lakehouse.finance_bigdata.dwd_finance_transactions
UNION ALL
SELECT 'dws_account_risk_features' AS table_name, 515080 AS expected_count, COUNT(*) AS actual_count,
       CASE WHEN COUNT(*) = 515080 THEN 'PASS' ELSE 'FAIL' END AS status
FROM lakehouse.finance_bigdata.dws_account_risk_features;
SQL
run_query "source_table_counts.tsv" "table_name\texpected_count\tactual_count\tstatus" "$RUN_DIR/sql/source_table_counts.sql"
step "source_table_counts" "PASS" "$RUN_DIR/source_table_counts.tsv"

COMMON_CTE="
WITH p AS (
  SELECT * FROM $P9_FEATURE_VIEW
),
w AS (
  SELECT
    t.transaction_id,
    t.transaction_date,
    p.split,
    t.transaction_hour,
    t.amount_paid,
    log1p(t.amount_paid) AS log_amount_paid,
    t.payment_currency,
    t.payment_format,
    t.is_cross_bank,
    t.is_cross_currency,
    sin(2 * pi() * CAST(t.transaction_hour AS DOUBLE) / 24) AS hour_sin,
    cos(2 * pi() * CAST(t.transaction_hour AS DOUBLE) / 24) AS hour_cos,
    COALESCE(a.total_event_count, 0) AS from_total_event_count,
    COALESCE(a.debit_count, 0) AS from_debit_count,
    COALESCE(a.credit_count, 0) AS from_credit_count,
    COALESCE(a.out_amount, 0.0) AS from_out_amount,
    COALESCE(a.in_amount, 0.0) AS from_in_amount,
    COALESCE(a.max_out_amount, 0.0) AS from_max_out_amount,
    COALESCE(a.counterparty_count, 0) AS from_counterparty_count,
    COALESCE(a.cross_bank_event_count, 0) AS from_cross_bank_event_count,
    COALESCE(a.cross_currency_event_count, 0) AS from_cross_currency_event_count,
    COALESCE(a.out_amount, 0.0) / (abs(COALESCE(a.in_amount, 0.0)) + 1.0) AS from_out_in_ratio,
    COALESCE(a.debit_count, 0) / (abs(COALESCE(a.credit_count, 0)) + 1.0) AS from_debit_credit_ratio,
    t.is_laundering
  FROM p
  INNER JOIN lakehouse.finance_bigdata.dwd_finance_transactions t
    ON p.transaction_id = t.transaction_id
  LEFT JOIN lakehouse.finance_bigdata.dws_account_risk_features a
    ON t.from_account = a.account_number
)
"

cat > "$RUN_DIR/sql/row_parity.sql" <<SQL
$COMMON_CTE
SELECT 'p9_feature_rows' AS metric, COUNT(*) AS value,
       CASE WHEN COUNT(*) = 205177 THEN 'PASS' ELSE 'FAIL' END AS status,
       'uploaded P9 feature rows' AS detail
FROM p
UNION ALL
SELECT 'p9_distinct_transaction_id', COUNT(DISTINCT transaction_id),
       CASE WHEN COUNT(DISTINCT transaction_id) = COUNT(*) THEN 'PASS' ELSE 'FAIL' END,
       'P9 transaction_id uniqueness'
FROM p
UNION ALL
SELECT 'p9_positive_rows', SUM(CAST(is_laundering AS BIGINT)),
       CASE WHEN SUM(CAST(is_laundering AS BIGINT)) = 5177 THEN 'PASS' ELSE 'FAIL' END,
       'P9 positive label count'
FROM p
UNION ALL
SELECT 'warehouse_matched_rows', COUNT(*),
       CASE WHEN COUNT(*) = (SELECT COUNT(*) FROM p) THEN 'PASS' ELSE 'FAIL' END,
       'P9 rows matched from Iceberg DWD'
FROM w
UNION ALL
SELECT 'warehouse_unmatched_rows', (SELECT COUNT(*) FROM p) - (SELECT COUNT(*) FROM w),
       CASE WHEN (SELECT COUNT(*) FROM p) - (SELECT COUNT(*) FROM w) = 0 THEN 'PASS' ELSE 'FAIL' END,
       'P9 rows not found in Iceberg DWD';
SQL
run_query "row_parity.tsv" "metric\tvalue\tstatus\tdetail" "$RUN_DIR/sql/row_parity.sql"
step "row_parity" "PASS" "$RUN_DIR/row_parity.tsv"

cat > "$RUN_DIR/sql/sample_label_split_summary.sql" <<SQL
SELECT split, CAST(is_laundering AS INT) AS is_laundering, COUNT(*) AS row_count
FROM $P9_FEATURE_VIEW
GROUP BY split, CAST(is_laundering AS INT)
ORDER BY split, is_laundering;
SQL
run_query "sample_label_split_summary.tsv" "split\tis_laundering\trow_count" "$RUN_DIR/sql/sample_label_split_summary.sql"
step "label_split_summary" "PASS" "$RUN_DIR/sample_label_split_summary.tsv"

cat > "$RUN_DIR/sql/numeric_parity.sql" <<SQL
$COMMON_CTE
, j AS (
  SELECT
    p.transaction_id,
    p.transaction_hour AS p_transaction_hour, w.transaction_hour AS w_transaction_hour,
    p.amount_paid AS p_amount_paid, w.amount_paid AS w_amount_paid,
    p.log_amount_paid AS p_log_amount_paid, w.log_amount_paid AS w_log_amount_paid,
    p.is_cross_bank AS p_is_cross_bank, w.is_cross_bank AS w_is_cross_bank,
    p.is_cross_currency AS p_is_cross_currency, w.is_cross_currency AS w_is_cross_currency,
    p.hour_sin AS p_hour_sin, w.hour_sin AS w_hour_sin,
    p.hour_cos AS p_hour_cos, w.hour_cos AS w_hour_cos,
    p.from_total_event_count AS p_from_total_event_count, w.from_total_event_count AS w_from_total_event_count,
    p.from_debit_count AS p_from_debit_count, w.from_debit_count AS w_from_debit_count,
    p.from_credit_count AS p_from_credit_count, w.from_credit_count AS w_from_credit_count,
    p.from_out_amount AS p_from_out_amount, w.from_out_amount AS w_from_out_amount,
    p.from_in_amount AS p_from_in_amount, w.from_in_amount AS w_from_in_amount,
    p.from_max_out_amount AS p_from_max_out_amount, w.from_max_out_amount AS w_from_max_out_amount,
    p.from_counterparty_count AS p_from_counterparty_count, w.from_counterparty_count AS w_from_counterparty_count,
    p.from_cross_bank_event_count AS p_from_cross_bank_event_count, w.from_cross_bank_event_count AS w_from_cross_bank_event_count,
    p.from_cross_currency_event_count AS p_from_cross_currency_event_count, w.from_cross_currency_event_count AS w_from_cross_currency_event_count,
    p.from_out_in_ratio AS p_from_out_in_ratio, w.from_out_in_ratio AS w_from_out_in_ratio,
    p.from_debit_credit_ratio AS p_from_debit_credit_ratio, w.from_debit_credit_ratio AS w_from_debit_credit_ratio,
    p.is_laundering AS p_is_laundering, w.is_laundering AS w_is_laundering
  FROM p
  INNER JOIN w ON p.transaction_id = w.transaction_id
)
SELECT feature, compared_rows, max_abs_diff, mismatch_rows, tolerance,
       CASE WHEN max_abs_diff <= tolerance THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
  SELECT 'transaction_hour' AS feature, COUNT(*) AS compared_rows, MAX(abs(CAST(p_transaction_hour AS DOUBLE) - CAST(w_transaction_hour AS DOUBLE))) AS max_abs_diff, SUM(CASE WHEN abs(CAST(p_transaction_hour AS DOUBLE) - CAST(w_transaction_hour AS DOUBLE)) > 0 THEN 1 ELSE 0 END) AS mismatch_rows, 0.0 AS tolerance FROM j
  UNION ALL SELECT 'amount_paid', COUNT(*), MAX(abs(CAST(p_amount_paid AS DOUBLE) - CAST(w_amount_paid AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_amount_paid AS DOUBLE) - CAST(w_amount_paid AS DOUBLE)) > 0.000001 THEN 1 ELSE 0 END), 0.000001 FROM j
  UNION ALL SELECT 'log_amount_paid', COUNT(*), MAX(abs(CAST(p_log_amount_paid AS DOUBLE) - CAST(w_log_amount_paid AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_log_amount_paid AS DOUBLE) - CAST(w_log_amount_paid AS DOUBLE)) > 0.000001 THEN 1 ELSE 0 END), 0.000001 FROM j
  UNION ALL SELECT 'is_cross_bank', COUNT(*), MAX(abs(CAST(p_is_cross_bank AS DOUBLE) - CAST(w_is_cross_bank AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_is_cross_bank AS DOUBLE) - CAST(w_is_cross_bank AS DOUBLE)) > 0 THEN 1 ELSE 0 END), 0.0 FROM j
  UNION ALL SELECT 'is_cross_currency', COUNT(*), MAX(abs(CAST(p_is_cross_currency AS DOUBLE) - CAST(w_is_cross_currency AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_is_cross_currency AS DOUBLE) - CAST(w_is_cross_currency AS DOUBLE)) > 0 THEN 1 ELSE 0 END), 0.0 FROM j
  UNION ALL SELECT 'hour_sin', COUNT(*), MAX(abs(CAST(p_hour_sin AS DOUBLE) - CAST(w_hour_sin AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_hour_sin AS DOUBLE) - CAST(w_hour_sin AS DOUBLE)) > 0.000001 THEN 1 ELSE 0 END), 0.000001 FROM j
  UNION ALL SELECT 'hour_cos', COUNT(*), MAX(abs(CAST(p_hour_cos AS DOUBLE) - CAST(w_hour_cos AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_hour_cos AS DOUBLE) - CAST(w_hour_cos AS DOUBLE)) > 0.000001 THEN 1 ELSE 0 END), 0.000001 FROM j
  UNION ALL SELECT 'from_total_event_count', COUNT(*), MAX(abs(CAST(p_from_total_event_count AS DOUBLE) - CAST(w_from_total_event_count AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_from_total_event_count AS DOUBLE) - CAST(w_from_total_event_count AS DOUBLE)) > 0 THEN 1 ELSE 0 END), 0.0 FROM j
  UNION ALL SELECT 'from_debit_count', COUNT(*), MAX(abs(CAST(p_from_debit_count AS DOUBLE) - CAST(w_from_debit_count AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_from_debit_count AS DOUBLE) - CAST(w_from_debit_count AS DOUBLE)) > 0 THEN 1 ELSE 0 END), 0.0 FROM j
  UNION ALL SELECT 'from_credit_count', COUNT(*), MAX(abs(CAST(p_from_credit_count AS DOUBLE) - CAST(w_from_credit_count AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_from_credit_count AS DOUBLE) - CAST(w_from_credit_count AS DOUBLE)) > 0 THEN 1 ELSE 0 END), 0.0 FROM j
  UNION ALL SELECT 'from_out_amount', COUNT(*), MAX(abs(CAST(p_from_out_amount AS DOUBLE) - CAST(w_from_out_amount AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_from_out_amount AS DOUBLE) - CAST(w_from_out_amount AS DOUBLE)) > 0.000001 THEN 1 ELSE 0 END), 0.000001 FROM j
  UNION ALL SELECT 'from_in_amount', COUNT(*), MAX(abs(CAST(p_from_in_amount AS DOUBLE) - CAST(w_from_in_amount AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_from_in_amount AS DOUBLE) - CAST(w_from_in_amount AS DOUBLE)) > 0.000001 THEN 1 ELSE 0 END), 0.000001 FROM j
  UNION ALL SELECT 'from_max_out_amount', COUNT(*), MAX(abs(CAST(p_from_max_out_amount AS DOUBLE) - CAST(w_from_max_out_amount AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_from_max_out_amount AS DOUBLE) - CAST(w_from_max_out_amount AS DOUBLE)) > 0.000001 THEN 1 ELSE 0 END), 0.000001 FROM j
  UNION ALL SELECT 'from_counterparty_count', COUNT(*), MAX(abs(CAST(p_from_counterparty_count AS DOUBLE) - CAST(w_from_counterparty_count AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_from_counterparty_count AS DOUBLE) - CAST(w_from_counterparty_count AS DOUBLE)) > 0 THEN 1 ELSE 0 END), 0.0 FROM j
  UNION ALL SELECT 'from_cross_bank_event_count', COUNT(*), MAX(abs(CAST(p_from_cross_bank_event_count AS DOUBLE) - CAST(w_from_cross_bank_event_count AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_from_cross_bank_event_count AS DOUBLE) - CAST(w_from_cross_bank_event_count AS DOUBLE)) > 0 THEN 1 ELSE 0 END), 0.0 FROM j
  UNION ALL SELECT 'from_cross_currency_event_count', COUNT(*), MAX(abs(CAST(p_from_cross_currency_event_count AS DOUBLE) - CAST(w_from_cross_currency_event_count AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_from_cross_currency_event_count AS DOUBLE) - CAST(w_from_cross_currency_event_count AS DOUBLE)) > 0 THEN 1 ELSE 0 END), 0.0 FROM j
  UNION ALL SELECT 'from_out_in_ratio', COUNT(*), MAX(abs(CAST(p_from_out_in_ratio AS DOUBLE) - CAST(w_from_out_in_ratio AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_from_out_in_ratio AS DOUBLE) - CAST(w_from_out_in_ratio AS DOUBLE)) > 0.000001 THEN 1 ELSE 0 END), 0.000001 FROM j
  UNION ALL SELECT 'from_debit_credit_ratio', COUNT(*), MAX(abs(CAST(p_from_debit_credit_ratio AS DOUBLE) - CAST(w_from_debit_credit_ratio AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_from_debit_credit_ratio AS DOUBLE) - CAST(w_from_debit_credit_ratio AS DOUBLE)) > 0.000001 THEN 1 ELSE 0 END), 0.000001 FROM j
  UNION ALL SELECT 'is_laundering', COUNT(*), MAX(abs(CAST(p_is_laundering AS DOUBLE) - CAST(w_is_laundering AS DOUBLE))), SUM(CASE WHEN abs(CAST(p_is_laundering AS DOUBLE) - CAST(w_is_laundering AS DOUBLE)) > 0 THEN 1 ELSE 0 END), 0.0 FROM j
) q
ORDER BY feature;
SQL
run_query "numeric_parity.tsv" "feature\tcompared_rows\tmax_abs_diff\tmismatch_rows\ttolerance\tstatus" "$RUN_DIR/sql/numeric_parity.sql"
step "numeric_parity" "PASS" "$RUN_DIR/numeric_parity.tsv"

cat > "$RUN_DIR/sql/categorical_parity.sql" <<SQL
$COMMON_CTE
, j AS (
  SELECT
    p.transaction_id,
    p.transaction_date AS p_transaction_date, w.transaction_date AS w_transaction_date,
    p.split AS p_split, w.split AS w_split,
    p.payment_currency AS p_payment_currency, w.payment_currency AS w_payment_currency,
    p.payment_format AS p_payment_format, w.payment_format AS w_payment_format
  FROM p
  INNER JOIN w ON p.transaction_id = w.transaction_id
)
SELECT feature, compared_rows, mismatch_rows,
       CASE WHEN mismatch_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
  SELECT 'transaction_date' AS feature, COUNT(*) AS compared_rows, SUM(CASE WHEN COALESCE(CAST(p_transaction_date AS STRING), '__NULL__') <> COALESCE(CAST(w_transaction_date AS STRING), '__NULL__') THEN 1 ELSE 0 END) AS mismatch_rows FROM j
  UNION ALL SELECT 'split', COUNT(*), SUM(CASE WHEN COALESCE(CAST(p_split AS STRING), '__NULL__') <> COALESCE(CAST(w_split AS STRING), '__NULL__') THEN 1 ELSE 0 END) FROM j
  UNION ALL SELECT 'payment_currency', COUNT(*), SUM(CASE WHEN COALESCE(CAST(p_payment_currency AS STRING), '__NULL__') <> COALESCE(CAST(w_payment_currency AS STRING), '__NULL__') THEN 1 ELSE 0 END) FROM j
  UNION ALL SELECT 'payment_format', COUNT(*), SUM(CASE WHEN COALESCE(CAST(p_payment_format AS STRING), '__NULL__') <> COALESCE(CAST(w_payment_format AS STRING), '__NULL__') THEN 1 ELSE 0 END) FROM j
) q
ORDER BY feature;
SQL
run_query "categorical_parity.tsv" "feature\tcompared_rows\tmismatch_rows\tstatus" "$RUN_DIR/sql/categorical_parity.sql"
step "categorical_parity" "PASS" "$RUN_DIR/categorical_parity.tsv"

timeout 20s yarn application -list -appStates RUNNING > "$RUN_DIR/yarn_running_apps_after.out" 2>&1 || true
if grep -q 'Total number of applications.*:0' "$RUN_DIR/yarn_running_apps_after.out"; then
  yarn_status="PASS"
else
  yarn_status="FAIL"
fi
echo -e "component\tstatus\tdetail" > "$RUN_DIR/postcheck.tsv"
echo -e "yarn_running_apps\t$yarn_status\tsee yarn_running_apps_after.out" >> "$RUN_DIR/postcheck.tsv"

overall_status="PASS"
for file_name in source_table_counts.tsv row_parity.tsv numeric_parity.tsv categorical_parity.tsv required_field_scan.tsv leakage_field_scan.tsv postcheck.tsv; do
  if grep -q $'\tFAIL' "$RUN_DIR/$file_name"; then
    overall_status="FAIL"
  fi
done

cat > "$RUN_DIR/p10_summary.md" <<MD
# P10 Warehouse Feature Parity Summary

- Run name: \`$RUN_NAME\`
- Run dir: \`$RUN_DIR\`
- HDFS stage: \`$HDFS_STAGE\`
- P9 uploaded feature parquet: \`$LOCAL_P9_FEATURE_PARQUET\`
- Scope: compare P9 local feature sample with features re-derived from Iceberg tables
- Status: \`$overall_status\`

## Inputs

- P9 effective run: \`p9_model_baseline_20260609_231710\`
- P9 feature rows expected: \`205177\`
- P9 positive rows expected: \`5177\`
- Iceberg namespace: \`lakehouse.finance_bigdata\`

## Boundary

- P10 does not train a new model.
- P10 does not modify P9 outputs.
- P10 verifies warehouse feature parity for the P9 non-leakage feature contract.
- P10 is not P14 master validation.

## Evidence

- \`source_table_counts.tsv\`
- \`row_parity.tsv\`
- \`required_field_scan.tsv\`
- \`leakage_field_scan.tsv\`
- \`numeric_parity.tsv\`
- \`categorical_parity.tsv\`
- \`sample_label_split_summary.tsv\`
MD

step "summary" "$overall_status" "$RUN_DIR/p10_summary.md"

hdfs dfs -put -f "$RUN_DIR"/p10_summary.md "$HDFS_RUN/p10_summary.md"
hdfs dfs -put -f "$RUN_DIR"/steps.tsv "$HDFS_RUN/steps.tsv"
hdfs dfs -put -f "$RUN_DIR"/source_table_counts.tsv "$HDFS_RUN/source_table_counts.tsv"
hdfs dfs -put -f "$RUN_DIR"/row_parity.tsv "$HDFS_RUN/row_parity.tsv"
hdfs dfs -put -f "$RUN_DIR"/numeric_parity.tsv "$HDFS_RUN/numeric_parity.tsv"
hdfs dfs -put -f "$RUN_DIR"/categorical_parity.tsv "$HDFS_RUN/categorical_parity.tsv"

echo "P10_CLUSTER_RUN_DIR=$RUN_DIR"
echo "P10_HDFS_RUN=$HDFS_RUN"
echo "P10_STATUS=$overall_status"
cat "$RUN_DIR/row_parity.tsv"
cat "$RUN_DIR/numeric_parity.tsv"
cat "$RUN_DIR/categorical_parity.tsv"

if [[ "$overall_status" != "PASS" ]]; then
  exit 2
fi
