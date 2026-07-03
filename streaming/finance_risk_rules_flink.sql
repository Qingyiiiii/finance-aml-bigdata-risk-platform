SET 'execution.runtime-mode' = 'streaming';
SET 'table.dml-sync' = 'false';
SET 'parallelism.default' = '1';
SET 'pipeline.name' = 'finance_p6_risk___RUN_ID__';

CREATE TEMPORARY TABLE finance_transactions (
  run_id STRING,
  transaction_id STRING,
  tx_timestamp STRING,
  transaction_minute STRING,
  from_bank STRING,
  from_account STRING,
  to_bank STRING,
  to_account STRING,
  amount_paid DOUBLE,
  payment_currency STRING,
  payment_format STRING,
  is_laundering INT,
  is_cross_bank INT,
  is_cross_currency INT
) WITH (
  'connector' = 'kafka',
  'topic' = '__INPUT_TOPIC__',
  'properties.bootstrap.servers' = 'hadoop1:9092',
  'properties.group.id' = '__GROUP_ID__',
  'scan.startup.mode' = 'earliest-offset',
  'format' = 'json',
  'json.ignore-parse-errors' = 'true'
);

CREATE TEMPORARY TABLE finance_risk_events (
  run_id STRING,
  transaction_id STRING,
  tx_timestamp STRING,
  transaction_minute STRING,
  event_account STRING,
  counterparty_account STRING,
  amount_paid DOUBLE,
  payment_currency STRING,
  payment_format STRING,
  is_laundering INT,
  is_cross_bank INT,
  is_cross_currency INT,
  risk_type STRING,
  risk_score INT,
  risk_reasons STRING
) WITH (
  'connector' = 'kafka',
  'topic' = '__RISK_TOPIC__',
  'properties.bootstrap.servers' = 'hadoop1:9092',
  'format' = 'json'
);

INSERT INTO finance_risk_events
SELECT
  run_id,
  transaction_id,
  tx_timestamp,
  transaction_minute,
  from_account AS event_account,
  to_account AS counterparty_account,
  amount_paid,
  payment_currency,
  payment_format,
  is_laundering,
  is_cross_bank,
  is_cross_currency,
  CASE
    WHEN is_laundering = 1 THEN 'LABEL_HIT'
    WHEN amount_paid >= 1000000 AND is_cross_currency = 1 THEN 'LARGE_CROSS_CURRENCY'
    WHEN amount_paid >= 1000000 AND is_cross_bank = 1 THEN 'LARGE_CROSS_BANK'
    WHEN amount_paid >= 1000000 THEN 'LARGE_AMOUNT'
    WHEN is_cross_currency = 1 THEN 'CROSS_CURRENCY'
    ELSE 'RULE_MATCH'
  END AS risk_type,
  CAST(
    (CASE WHEN is_laundering = 1 THEN 5 ELSE 0 END) +
    (CASE WHEN amount_paid >= 1000000 THEN 2 ELSE 0 END) +
    (CASE WHEN is_cross_bank = 1 THEN 1 ELSE 0 END) +
    (CASE WHEN is_cross_currency = 1 THEN 1 ELSE 0 END)
    AS INT
  ) AS risk_score,
  CONCAT(
    CASE WHEN is_laundering = 1 THEN 'LABEL_HIT;' ELSE '' END,
    CASE WHEN amount_paid >= 1000000 THEN 'LARGE_AMOUNT;' ELSE '' END,
    CASE WHEN is_cross_bank = 1 THEN 'CROSS_BANK;' ELSE '' END,
    CASE WHEN is_cross_currency = 1 THEN 'CROSS_CURRENCY;' ELSE '' END
  ) AS risk_reasons
FROM finance_transactions
WHERE run_id = '__RUN_ID__'
  AND (
    is_laundering = 1
    OR amount_paid >= 1000000
    OR is_cross_currency = 1
  );
