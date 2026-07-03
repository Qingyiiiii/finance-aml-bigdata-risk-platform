# Project Optimization Summary

Language: [中文](项目优化总结_zh.md) | [English](Project-Optimization-Summary_en.md)

This document records the goal, scripts, execution scope and future optimization direction for each project phase. Project boundary: all evidence and code are limited to this repository, and no external project is used as validation evidence.

### General Execution Scope

- Default dataset: `HI-Small`.
- The current host does not process Large data. Large raw files have been removed from `datas` and can be reconsidered after hardware capacity is upgraded.
- Medium data is retained for future expansion validation and is not part of the current default P3-P4 flow.
- Local phases do not connect to the virtual-machine cluster and do not submit Spark, Flink, Trino, Doris or Kafka tasks.
- All evidence is written under `data/finance_bigdata/runs`.
- Issues are recorded in `Optimize/Summary-of-Problem-Investigation_en.md`.

### P0 Project Foundation and Data Preflight

- Goal: confirm that raw files exist, fields are readable, data volume is recorded and independent project evidence is created.
- Script: `src/00_finance_preflight.py`
- Entry: `bin/p0_p2_local_smoke.ps1`
- Scope: read only `datas/HI-Small_*` and do not connect to the cluster.

### P1 Data Profiling

- Goal: profile the transaction table, account table and pattern reference file.
- Script: `src/01_finance_profile.py`
- Entry: `bin/p0_p2_local_smoke.ps1`
- Scope: scan the full `HI-Small_Trans.csv` without loading everything into memory at once.

### P2 ODS Small Sample

- Goal: generate a standard-field ODS sample and validate naming, type conversion and Parquet write capability.
- Script: `src/02_finance_ods_sample.py`
- Entry: `bin/p0_p2_local_smoke.ps1`
- Scope: write a default 100,000-row sample.

### P3 DWD Detail Layer

- Goal: build transaction detail, account dimension and transaction event tables, then validate account-dimension joins.
- Script: `src/03_finance_dwd_build.py`
- Entry: `bin/p3_p4_local_build.ps1`
- Result: PASS.
- Key outputs: DWD transaction detail, account dimension and transaction event table.
- Key metrics: 5,078,345 transaction-detail rows, 10,156,690 event rows, 518,581 account-dimension rows, 518,573 unique accounts and 100% account match rate.

### P4 DWS Risk KPI Layer

- Goal: build minute-level transaction KPI, account-level risk features, payment-format risk KPI and high-value transaction candidates.
- Script: `src/04_finance_dws_risk_kpi.py`
- Entry: `bin/p3_p4_local_build.ps1`
- Result: PASS.
- Key metrics: 88,316 minute KPI rows, 515,080 account risk feature rows, 7 payment-format KPI rows and 200,403 high-value candidates.

### P5 Hive/Iceberg Cluster Publish

- Goal: start the base platform, publish P3/P4 Parquet outputs as project-specific Iceberg tables and validate query prerequisites.
- Main script: `bin/p5_cluster_publish.sh`
- Scope: start HDFS/YARN, PostgreSQL, Hive Metastore and HiveServer2 only.
- Result: PASS.
- Key output: 7 Iceberg tables under `lakehouse.finance_bigdata`.
- Validation: table-level `COUNT(*)` results align with P3/P4 local summaries, and no YARN application remains running after P5.

### P6 Kafka/Flink/Redis Realtime Risk Loop

- Goal: replay 10,000 finance transaction samples into Kafka, generate risk events with Flink SQL rules and write latest-state results to Redis.
- Scripts: `streaming/finance_make_replay_sample.py`, `streaming/finance_collect_risk_to_redis.py`, `streaming/finance_risk_rules_flink.sql`, `bin/p6_cluster_realtime_demo.sh`
- Scope: start Kafka, Redis and Flink only.
- Result: PASS.
- Key metrics: 10,000 replayed events, 559 risk events and 489 Redis latest-state keys.

### P7 Readiness Snapshot

- Goal: freeze the current platform and project state, then confirm that P0-P6 evidence and cluster state are reviewable.
- Scripts: `bin/p7_cluster_readiness_snapshot.sh`, `bin/p7_local_readiness_snapshot.ps1`
- Scope: read-only snapshot and Spark SQL row-count checks.
- Result: PASS.
- Key outputs: component status, namespace snapshot, table counts, realtime snapshot and local evidence snapshot.

### P8 Delivery and Demo Package

- Goal: freeze accepted P0-P7 outputs and build portfolio delivery/demo materials.
- Script: `bin/p8_build_delivery_package.ps1`
- Scope: copy only summaries, TSV files and small samples. Raw CSV, large CSV and Parquet detail files are excluded.
- Result: PASS.
- Key outputs: delivery index, phase summary, evidence manifest, architecture overview, lineage document and demo script.

### P9 EDA, Feature Engineering and Baseline Model

- Goal: build label analysis, modeling feature samples and explainable AML classification baselines from accepted P3/P4 data layers.
- Scripts: `analysis/p9_label_eda.py`, `analysis/p9_feature_build.py`, `analysis/p9_baseline_model.py`
- Entry: `bin/p9_local_model_baseline.ps1`
- Result: PASS.
- Key metrics: 205,177 feature rows, 5,177 positive samples and best model `random_forest_balanced` with PR-AUC 0.741912, recall 0.909583 and precision 0.210894.
- Boundary: P9 is a portfolio baseline model, not a production risk model.

### P10 Warehouse Feature Parity

- Goal: validate that Iceberg warehouse tables can reproduce the non-leakage modeling feature scope from P9.
- Scripts: `bin/p10_cluster_feature_parity.sh`, `bin/p10_local_feature_parity.ps1`
- Result: PASS.
- Key metrics: all 205,177 P9 feature sample rows match Iceberg DWD, numeric parity 19/19 PASS, categorical parity 4/4 PASS and leakage scan 4/4 PASS.
- Boundary: P10 validates feature parity only. It does not train a new model or replace P14 master validation.

### P11 Realtime Scoring Contract

- Goal: define realtime input/output schema on top of P9/P10 non-leakage features and validate a Kafka/Flink/Redis scoring-contract loop.
- Contract: `contracts/p11_realtime_scoring_contract_en.md`
- Entry: `bin/p11_local_realtime_scoring_contract.ps1`
- Result: PASS.
- Key metrics: 10,000 input samples, 8,119 risk events, 0 schema-invalid events and 6,451 Redis keys.
- Boundary: P11 validates realtime scoring contracts and does not train a new model.

### P12 Trino/Doris Query Layer Validation

- Goal: validate that Iceberg tables, P11 realtime residues and Doris historical smoke metrics can be consumed by the query layer.
- Entry: `bin/p12_local_query_layer_validation.ps1`
- Result: PASS.
- Key metrics: 7 Iceberg tables pass row-count validation, 4 business query groups pass and P11 Redis key count is 6,451.
- Boundary: P12 does not rebuild P9/P10/P11 and does not replace P14 master validation.

### P13 BI Dashboard Material Package

- Goal: convert P12 query outputs and P11 realtime summaries into portable BI dashboard materials.
- Entry: `bin/p13_build_bi_dashboard_package.ps1`
- Result: PASS.
- Key outputs: dashboard index, metric catalog, page design, SQL reference, demo script and static HTML preview.
- Boundary: P13 does not connect to the cluster, submit jobs, train models or rebuild data layers.

### P14 Independent Finance Master Validation

- Goal: independently validate accepted P0-P13 evidence, key metrics, boundary isolation and delivery readiness.
- Entry: `bin/p14_finance_master_validation.ps1`
- Result: PASS.
- Key metrics: phase evidence 14/14 PASS, key metrics 26/26 PASS, boundary scan 8/8 PASS and delivery readiness 7/7 PASS.
- Boundary: P14 is project-specific master validation and does not use external project evidence.

### P15 Restart Readiness

- Goal: validate that required services can recover in sequence after a virtual-machine restart and that Iceberg tables and realtime components remain usable.
- Entry: `bin/p15_local_restart_readiness.ps1`
- Result: PASS.
- Key metrics: local startup steps 6/6 PASS, components 9/9 PASS, Iceberg tables 7/7 PASS, P6 Redis keys 489 and P11 Redis keys 6,451.
- Boundary: P15 is a restart recovery check and does not rebuild business data.

### P16 AI Explainability Enhancement

- Goal: turn P9 model results into display-ready model explanation materials and add an unsupervised anomaly detection experiment.
- Entry: `bin/p16_local_ai_learning.ps1`
- Result: PASS.
- Key metrics: best P9 model `random_forest_balanced`, PR-AUC 0.741912, Isolation Forest sample size 50,000 and anomaly lift 1.27487.
- Boundary: P16 does not replace P9/P14 and does not claim production AML performance.

### P17 Data Quality and Monitoring Rules

- Goal: convert accepted P0-P16 evidence into reusable data quality rules and a monitoring-rule baseline.
- Entry: `bin/p17_data_quality_check.ps1`
- Result: PASS.
- Key metrics: 20 checks, 20 PASS, 0 WARN and 0 FAIL.
- Boundary: P17 is quality-rule documentation and checking, not a new ETL layer or P14 replacement.

### P18 Final Portfolio Package

- Goal: generate a lightweight portfolio display package that connects P13 BI, P14 master validation, P15 restart readiness, P16 AI explainability and P17 data quality rules.
- Entry: `bin/p18_build_portfolio_final_package.ps1`
- Result: PASS.
- Key metrics: P14/P15/P16/P17 statuses all PASS, package file count 21, raw CSV or Parquet file count 0 and required missing file count 0.
- Boundary: P18 is the final portfolio package. It does not perform new business data processing and does not replace P14/P17.

