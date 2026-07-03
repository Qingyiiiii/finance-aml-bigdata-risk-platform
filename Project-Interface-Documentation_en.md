# Project Interface Documentation

Language: [中文](项目接口文档_zh.md) | [English](Project-Interface-Documentation_en.md)

Last updated: 2026-07-03

This file defines project interfaces for the environment, data, scripts, tables, realtime streams, query layers and validation. It is intended for public repository reproduction and display. All paths use repository-relative paths or generic cluster paths.

### 1. Environment Interface

| Item | Value |
| --- | --- |
| Local project root | `<repo-root>` |
| Local data directory | `datas/` |
| Local configuration | `config/finance_bigdata.local.yaml` |
| Cluster configuration | `config/finance_bigdata.cluster.yaml` |
| Linux project path | `/home/common/tmp/finance_bigdata_project` |
| HDFS project path | `/lakehouse/projects/finance_bigdata` |
| V1 output directory | `data/finance_bigdata` |
| V2 output directory | `data/finance_bigdata_v2` |
| Spark catalog / namespace | `lakehouse.finance_bigdata` |
| Trino catalog / schema | `iceberg.finance_bigdata` |
| Kafka topic prefix | `finance` |
| Redis key prefix | `finance_bigdata` |
| V2 ClickHouse database | `finance_bigdata_v2` |
| V2 Elasticsearch index | `finance-risk-events-v2` |

### 2. Data Interface

Default raw files:

| File | Purpose |
| --- | --- |
| `datas/HI-Small_Trans.csv` | Transaction detail input |
| `datas/HI-Small_accounts.csv` | Account dimension input |
| `datas/HI-Small_Patterns.txt` | AML pattern reference input |

Core fields:

| Field Group | Meaning | Consumer Phases |
| --- | --- | --- |
| `Timestamp` | Transaction timestamp | P1, P3, P4, P9, P11 |
| `From Bank` / `To Bank` | Payer and receiver bank | P3, P4, P9, P11 |
| `Account` | Account identifier | P3, P4, P11v2 |
| `Amount Paid` / `Amount Received` | Transaction amount | P1, P4, P9, P11 |
| `Payment Currency` / `Receiving Currency` | Currency | P3, P4, P11 |
| `Payment Format` | Payment method | P4, P9 |
| `Is Laundering` | Synthetic label | P1, P9, P16 |

The default validation scope is `HI-Small`. `Medium` and `Large` are excluded from default public validation.

### 3. Local Offline Interface

| Phase | Script | Input | Output |
| --- | --- | --- | --- |
| P0 | `src/00_finance_preflight.py` | Config and raw files | `preflight_report.md`, `summary.tsv` |
| P1 | `src/01_finance_profile.py` | Raw transaction and account files | `profile_summary.md`, `profile_metrics.tsv` |
| P2 | `src/02_finance_ods_sample.py` | Transaction CSV | ODS sample and schema summary |
| P3 | `src/03_finance_dwd_build.py` | Raw transaction and account files | DWD transaction, account and event tables |
| P4 | `src/04_finance_dws_risk_kpi.py` | P3 DWD outputs | DWS risk KPI and candidate details |

Local orchestration entry points:

```powershell
powershell -ExecutionPolicy Bypass -File .\bin\p0_p2_local_smoke.ps1
powershell -ExecutionPolicy Bypass -File .\bin\p3_p4_local_build.ps1
```

Default output pattern:

```text
data/finance_bigdata/runs/p0_preflight_*/
data/finance_bigdata/runs/p1_profile_*/
data/finance_bigdata/runs/p2_ods_sample_*/
data/finance_bigdata/runs/p3_dwd_build_*/
data/finance_bigdata/runs/p4_dws_risk_kpi_*/
```

### 4. Lakehouse Publish Interface

| Script | Responsibility |
| --- | --- |
| `bin/p5_cluster_publish.sh` | Publish P3/P4 Parquet outputs to Iceberg |
| `bin/p7_cluster_readiness_snapshot.sh` | Check base services, tables, topics, cache and local evidence |
| `bin/cluster_ssh.py` | Common executor for remote commands, uploads and evidence downloads |

Core Iceberg tables:

| Table | Description |
| --- | --- |
| `dwd_finance_transactions` | Transaction detail |
| `dwd_finance_accounts` | Account dimension |
| `dwd_finance_transaction_events` | Debit/credit event table |
| `dws_minute_transaction_kpi` | Minute-level transaction KPI |
| `dws_account_risk_features` | Account risk profile |
| `dws_payment_format_kpi` | Payment-format KPI |
| `dws_large_transaction_candidates` | High-value transaction candidates |

### 5. Realtime Flow Interface

| Flow | File | Responsibility |
| --- | --- | --- |
| P6 | `streaming/finance_make_replay_sample.py` | Generate Kafka replay samples from DWD |
| P6 | `streaming/finance_risk_rules_flink.sql` | Output Flink rule-based risk events |
| P6 | `streaming/finance_collect_risk_to_redis.py` | Validate risk events and write Redis latest-state data |
| P11 | `streaming/finance_make_scoring_contract_sample.py` | Generate scoring contract samples |
| P11 | `streaming/finance_scoring_contract_flink.sql` | Realtime scoring rule SQL |
| P11 | `streaming/finance_collect_contract_to_redis.py` | Validate P11 risk events and write cache data |
| P11v2 | `streaming/finance_make_p11v2_state_sample.py` | Generate V2 risk event samples |
| P11v2 | `streaming/finance_p11v2_state_flink.sql` | V2 state scoring SQL |
| P11v2 | `streaming/finance_collect_p11v2_state.py` | Write Redis cache and HBase durable state |

Local orchestration entry points:

```powershell
powershell -ExecutionPolicy Bypass -File .\bin\p11_local_realtime_scoring_contract.ps1
powershell -ExecutionPolicy Bypass -File .\bin\p11v2_local_realtime_state.ps1
```

V2 realtime-state boundary:

- Redis is the latest-state cache.
- HBase is the durable account risk state layer.
- Flink SQL rule scores are explainable rule scores, not production model probabilities.
- P11v2 does not depend on ClickHouse, Elasticsearch or BI packages as primary validation conditions.

### 6. Query and Display Interface

| Phase | Entry | Output |
| --- | --- | --- |
| P12 | `bin/p12_local_query_layer_validation.ps1` | Trino table counts, business queries and Doris historical smoke |
| P13 | `bin/p13_build_bi_dashboard_package.ps1` | V1 static BI material package |
| P12v2 | `bin/p12v2_local_clickhouse_es_validation.ps1` | ClickHouse ADS queries and Elasticsearch search results |
| P12v2 reference | `bin/p12v2_local_query_investigation.ps1` | Trino plus ClickHouse plus Elasticsearch reference flow |
| P13v2 | Static material package generation | ClickHouse-backed BI package |

V2 query-layer responsibilities:

| Component | Responsibility |
| --- | --- |
| Trino | Cross-query Iceberg fact tables |
| ClickHouse | ADS/BI display queries |
| Elasticsearch | Risk event investigation search |
| OpenSearch | Backup component, excluded from main validation |

### 7. AI and Quality Interface

| Phase | Entry | Description |
| --- | --- | --- |
| P9 | `bin/p9_local_model_baseline.ps1` | EDA, feature sample and baseline model |
| P10 | `bin/p10_local_feature_parity.ps1` | Parity between Iceberg-derived features and local features |
| P16 | `bin/p16_local_ai_learning.ps1` | Model explanation and anomaly detection experiment |
| P17 | `bin/p17_data_quality_check.ps1` | V1 local quality rule check |
| P17v2 | `bin/p17v2_local_gx_quality_check.ps1` | V2 Great Expectations quality gate |

Boundary: P9/P16 are experiments and explainability analyses, not production AML models. P17v2 reads accepted V2 evidence and does not rerun the business pipeline.

### 8. Validation Interface

| Phase | Entry | Conclusion Source |
| --- | --- | --- |
| P14 | `bin/p14_finance_master_validation.ps1` | `summary.tsv`, `phase_evidence_status.tsv`, `boundary_scan.tsv` |
| P15 | `bin/p15_local_restart_readiness.ps1` | `component_status.tsv`, `table_counts.tsv`, `realtime_restart_status.tsv` |
| P18 | `bin/p18_build_portfolio_final_package.ps1` | `p18_status.tsv`, display entry and package boundary scan |
| P14v2 | `bin/p14v2_master_validation.ps1` | V2 evidence matrix, component validation and boundary scan |
| P18v2 | `bin/p18v2_build_portfolio_final_package.ps1` | V2 display package, manifest and package boundary scan |

Formal conclusions read only the status tables, summaries, matrices and boundary scans from the corresponding run directories. Smoke results cannot replace P14/P14v2 master validation.

### 9. Configuration Interface

| File | Key Fields |
| --- | --- |
| `config/finance_bigdata.local.yaml` | `paths.raw_dir`, `paths.output_dir`, `processing.sample_rows`, `namespace.*` |
| `config/finance_bigdata.cluster.yaml` | `paths.linux_project_root`, `paths.hdfs_root`, `namespace.*`, `publish.*` |

Public repository configuration stores only reproducible template parameters. Sensitive values required for cluster access should be stored in private local configuration, and script outputs must not write those values back into regular documents.

### 10. Display Safety Boundary

- Use repository-relative paths for local inputs and outputs.
- Keep only generic project paths and service paths for cluster-side references.
- Display packages contain only small Markdown, TSV, JSON and HTML evidence.
- Raw large files, runtime logs, large detail datasets and local sensitive configuration must not enter public packages.
- V1, V2, backup components and historical components must be described separately.

