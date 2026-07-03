SET 'execution.runtime-mode' = 'streaming';
SET 'table.dml-sync' = 'false';
SET 'parallelism.default' = '1';
SET 'pipeline.name' = 'finance_p11_scoring_contract___RUN_ID__';

CREATE TEMPORARY TABLE finance_scoring_input (
  run_id STRING,
  contract_version STRING,
  transaction_id STRING,
  tx_timestamp STRING,
  transaction_date STRING,
  transaction_hour INT,
  from_account STRING,
  to_account STRING,
  amount_paid DOUBLE,
  log_amount_paid DOUBLE,
  payment_currency STRING,
  payment_format STRING,
  is_cross_bank INT,
  is_cross_currency INT,
  hour_sin DOUBLE,
  hour_cos DOUBLE,
  from_total_event_count BIGINT,
  from_debit_count BIGINT,
  from_credit_count BIGINT,
  from_out_amount DOUBLE,
  from_in_amount DOUBLE,
  from_max_out_amount DOUBLE,
  from_counterparty_count BIGINT,
  from_cross_bank_event_count BIGINT,
  from_cross_currency_event_count BIGINT,
  from_out_in_ratio DOUBLE,
  from_debit_credit_ratio DOUBLE,
  observed_is_laundering INT,
  `split` STRING,
  feature_snapshot_version STRING
) WITH (
  'connector' = 'kafka',
  'topic' = '__INPUT_TOPIC__',
  'properties.bootstrap.servers' = 'hadoop1:9092',
  'properties.group.id' = '__GROUP_ID__',
  'scan.startup.mode' = 'earliest-offset',
  'format' = 'json',
  'json.ignore-parse-errors' = 'true'
);

CREATE TEMPORARY TABLE finance_scoring_output (
  run_id STRING,
  contract_version STRING,
  transaction_id STRING,
  event_time STRING,
  event_account STRING,
  counterparty_account STRING,
  amount_paid DOUBLE,
  payment_currency STRING,
  payment_format STRING,
  feature_snapshot_version STRING,
  risk_score INT,
  risk_level STRING,
  risk_reasons STRING,
  rule_hits STRING,
  scored_at STRING
) WITH (
  'connector' = 'kafka',
  'topic' = '__RISK_TOPIC__',
  'properties.bootstrap.servers' = 'hadoop1:9092',
  'format' = 'json'
);

INSERT INTO finance_scoring_output
SELECT
  run_id,
  'p11_realtime_scoring_contract_v1' AS contract_version,
  transaction_id,
  tx_timestamp AS event_time,
  from_account AS event_account,
  to_account AS counterparty_account,
  amount_paid,
  payment_currency,
  payment_format,
  feature_snapshot_version,
  CASE WHEN raw_score > 100 THEN 100 ELSE raw_score END AS risk_score,
  CASE
    WHEN raw_score >= 80 THEN 'CRITICAL'
    WHEN raw_score >= 60 THEN 'HIGH'
    WHEN raw_score >= 30 THEN 'MEDIUM'
    ELSE 'LOW'
  END AS risk_level,
  CONCAT(
    CASE WHEN amount_paid >= 10000000 THEN 'AMOUNT_GE_10M;' WHEN amount_paid >= 1000000 THEN 'AMOUNT_GE_1M;' ELSE '' END,
    CASE WHEN is_cross_currency = 1 THEN 'CROSS_CURRENCY;' ELSE '' END,
    CASE WHEN is_cross_bank = 1 THEN 'CROSS_BANK;' ELSE '' END,
    CASE WHEN from_cross_currency_event_count >= 2 THEN 'ACCOUNT_CROSS_CURRENCY_GE_2;' ELSE '' END,
    CASE WHEN from_cross_bank_event_count >= 10 THEN 'ACCOUNT_CROSS_BANK_GE_10;' ELSE '' END,
    CASE WHEN from_debit_credit_ratio >= 3 THEN 'DEBIT_CREDIT_RATIO_GE_3;' ELSE '' END,
    CASE WHEN from_out_in_ratio >= 3 THEN 'OUT_IN_RATIO_GE_3;' ELSE '' END
  ) AS risk_reasons,
  CONCAT(
    CASE WHEN amount_paid >= 10000000 THEN 'R_AMOUNT_10M;' WHEN amount_paid >= 1000000 THEN 'R_AMOUNT_1M;' ELSE '' END,
    CASE WHEN is_cross_currency = 1 THEN 'R_CROSS_CURRENCY;' ELSE '' END,
    CASE WHEN is_cross_bank = 1 THEN 'R_CROSS_BANK;' ELSE '' END,
    CASE WHEN from_cross_currency_event_count >= 2 THEN 'R_ACCOUNT_CROSS_CURRENCY;' ELSE '' END,
    CASE WHEN from_cross_bank_event_count >= 10 THEN 'R_ACCOUNT_CROSS_BANK;' ELSE '' END,
    CASE WHEN from_debit_credit_ratio >= 3 THEN 'R_DEBIT_CREDIT_RATIO;' ELSE '' END,
    CASE WHEN from_out_in_ratio >= 3 THEN 'R_OUT_IN_RATIO;' ELSE '' END
  ) AS rule_hits,
  CAST(CURRENT_TIMESTAMP AS STRING) AS scored_at
FROM (
  SELECT
    *,
    CAST(
      (CASE WHEN amount_paid >= 10000000 THEN 35 WHEN amount_paid >= 1000000 THEN 25 ELSE 0 END) +
      (CASE WHEN is_cross_currency = 1 THEN 20 ELSE 0 END) +
      (CASE WHEN is_cross_bank = 1 THEN 10 ELSE 0 END) +
      (CASE WHEN from_cross_currency_event_count >= 2 THEN 15 ELSE 0 END) +
      (CASE WHEN from_cross_bank_event_count >= 10 THEN 10 ELSE 0 END) +
      (CASE WHEN from_debit_credit_ratio >= 3 THEN 10 ELSE 0 END) +
      (CASE WHEN from_out_in_ratio >= 3 THEN 10 ELSE 0 END)
      AS INT
    ) AS raw_score
  FROM finance_scoring_input
  WHERE run_id = '__RUN_ID__'
    AND contract_version = 'p11_realtime_scoring_contract_v1'
)
WHERE raw_score >= 30;
