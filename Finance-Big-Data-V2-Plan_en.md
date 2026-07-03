# Finance Big Data V2 Plan

Language: [中文](金融大数据v2版本方案_zh.md) | [English](Finance-Big-Data-V2-Plan_en.md)

Last updated: 2026-07-03

This document defines the V2 architecture direction, phase responsibilities, validation boundaries and future extension strategy for the finance big-data platform. It is a public display version and does not record temporary work notes, local environment paths, long installation logs or sensitive configuration values.

### 1. V2 Positioning

V1 has completed the end-to-end workflow: local offline warehouse processing, lakehouse publishing, realtime risk control, query layer, BI materials, AI experiments, quality checks and lightweight delivery packaging.

V2 does not replace V1. It upgrades the project into a more finance-oriented transaction risk platform under an independent output directory:

```text
Transaction stream -> Risk scoring -> Account state -> Query/search -> BI display -> Quality gate -> Governance/monitoring -> Independent master validation
```

Core V2 principles:

- Keep V1 evidence intact and generate V2 evidence independently.
- Demote Redis from source-of-truth state to cache.
- Use HBase for recoverable account risk state.
- Use ClickHouse as the V2 OLAP/BI display layer.
- Use Elasticsearch as the V2 risk-event investigation search layer.
- Use Great Expectations as the V2 data quality gate.
- Keep Ranger, Atlas, Prometheus and Grafana within minimal governance and monitoring validation.
- Display packages copy only small readable evidence and do not include local sensitive configuration or large detail data.

### 2. V2 Main Flow

```text
Kafka transaction events
  -> Flink rules and scoring
  -> Redis latest-state cache
  -> HBase durable account state
  -> ClickHouse ADS / BI
  -> Elasticsearch investigation index
  -> Great Expectations quality gate
  -> P14v2 master validation
  -> P18v2 display package
```

### 3. Phase Design

| Phase | Goal | Main Entry | Main Output |
| --- | --- | --- | --- |
| P11v2 | Land realtime account state | `bin/p11v2_local_realtime_state.ps1` | Redis cache, HBase durable state and risk event evidence |
| P12v2 | Validate query and investigation search | `bin/p12v2_local_clickhouse_es_validation.ps1` | ClickHouse query results and Elasticsearch search samples |
| P13v2 | Build BI display materials | Static package generation script | Metric catalog, page design and preview HTML |
| P15v2 | Validate modular recovery readiness | `bin/p15v2_local_low_memory_readiness.ps1` | Service status, memory snapshots and release records |
| P17v2 | Run data quality gate | `bin/p17v2_local_gx_quality_check.ps1` | GX result, quality rules and check details |
| P14v2 | Run independent master validation | `bin/p14v2_master_validation.ps1` | V2 validation matrix, component validation and boundary scan |
| P18v2 | Build lightweight display package | `bin/p18v2_build_portfolio_final_package.ps1` | Display entry, evidence manifest and package boundary scan |

Recommended dependency order:

```text
P11v2 -> P12v2 -> P13v2 -> P15v2 -> P17v2 -> P14v2 -> P18v2
```

### 4. P11v2 Realtime State Landing

Goal: upgrade the cache-oriented V1 realtime result into recoverable and queryable account risk state.

Inputs:

- Non-leakage feature definitions from P9/P10.
- P11v2 risk event samples.
- Minimal Kafka/Flink/Redis/HBase realtime dependencies.

Outputs:

- `risk_events_raw.jsonl`
- `p11v2_state_summary.tsv`
- `hbase_readback_sample.tsv`
- Redis/HBase consistency checks

Validation boundary:

- Redis is only the latest-state cache.
- HBase stores durable account risk state.
- Flink rule scoring is explainable scoring and is not declared as a production model probability.
- P11v2 does not require ClickHouse, Elasticsearch or BI packages as primary validation conditions.

### 5. P12v2 Query and Investigation Search

Goal: move the V2 query/display layer from the V1 Doris historical smoke path to ClickHouse plus Elasticsearch.

| Component | Responsibility |
| --- | --- |
| Trino | Cross-query Iceberg fact tables |
| ClickHouse | ADS/BI display queries |
| Elasticsearch | Risk event investigation search |
| OpenSearch | Backup component, excluded from main validation |

Outputs:

- `clickhouse_query_results.tsv`
- `clickhouse_query_status.tsv`
- `elasticsearch_index_status.tsv`
- `elasticsearch_search_sample.json`
- `postcheck.tsv`

Validation boundary:

- ClickHouse is a display layer, not the source of truth.
- Elasticsearch is a search replica, not the source of truth.
- Doris is excluded from V2 main validation.
- OpenSearch cannot replace Elasticsearch as V2 main evidence.

### 6. P13v2 BI Display Package

Goal: organize the lightweight query and search outputs from P12v2 into readable, display-ready and portable BI materials.

Outputs:

- `dashboard_index.md`
- `dashboard_preview.html`
- `dashboard_metric_catalog.md`
- `dashboard_page_design.md`
- `dashboard_sql_reference.md`
- `package_boundary_scan.tsv`

Boundary:

- Do not reconnect to the cluster.
- Do not rerun P11v2/P12v2.
- Do not generate master validation conclusions.
- Copy only small Markdown, TSV, JSON and HTML materials.
- Do not copy raw data, large detail files, bulk responses or local sensitive configuration.

### 7. P15v2 Modular Recovery Readiness

Goal: prove that V2 components can be started, checked and released on demand in a low-memory cluster, instead of requiring all components to stay resident.

Execution mode: `low_memory_sequential`

| Module | Checkpoint |
| --- | --- |
| base platform | HDFS, YARN, PostgreSQL, Hive Metastore and Iceberg |
| realtime module | Kafka, Redis, Flink, ZooKeeper and HBase |
| query/search module | Trino, ClickHouse and Elasticsearch |
| governance module | Minimal Ranger and Atlas readiness |
| monitoring module | Lightweight Prometheus and Grafana accessibility |
| backup components | OpenSearch, Deequ and Soda status recording |

Boundary:

- Do not rebuild business data.
- Do not rerun P11v2/P12v2.
- Do not rebuild the P13v2 BI package.
- Do not require all V2 components to stay resident at the same time.
- Release heavy components after validation to reduce memory pressure.

### 8. P17v2 Data Quality Gate

Goal: use Great Expectations to read accepted V2 evidence and produce a repeatable data quality gate.

Inputs:

- P11v2 state evidence.
- P12v2 query and search evidence.
- P13v2 BI package status.
- P15v2 modular recovery status.

Outputs:

- `quality_check_results.tsv`
- `quality_rule_catalog.md`
- `gx_validation_result.json`
- `gx_checkpoint_summary.tsv`
- `source_evidence_manifest.tsv`

Boundary:

- Read existing evidence only.
- Do not start the full cluster.
- Do not rewrite HBase, ClickHouse or Elasticsearch.
- Do not replace P14v2 independent master validation.

### 9. P14v2 Independent Master Validation

Goal: consolidate evidence from P11v2, P12v2, P13v2, P15v2 and P17v2 into a V2 validation matrix.

Outputs:

- `summary.tsv`
- `phase_evidence_status.tsv`
- `v2_validation_matrix.tsv`
- `component_validation.tsv`
- `key_metric_validation.tsv`
- `boundary_scan.tsv`

Pass conditions:

- Phase evidence is complete.
- HBase, ClickHouse, Elasticsearch, GX, governance, monitoring and modular recovery all have corresponding check results.
- Boundary scan has no failed item.
- V1 results are not used as substitutes for V2 results.
- The script does not start the cluster or rerun business pipelines.

### 10. P18v2 Display Package

Goal: after P14v2 passes, generate a lightweight, portable and display-ready V2 package.

Outputs:

- `portfolio_index.md`
- `accepted_evidence_manifest.tsv`
- `copied_materials_manifest.tsv`
- `package_boundary_scan.tsv`
- `p18v2_summary.md`

Boundary:

- Do not perform new computation.
- Do not perform new master validation.
- Do not process raw data.
- Do not copy large detail files or local sensitive configuration.
- Do not overwrite V1 display packages.

### 11. Reusable Assets

V2 can reuse the following V1 assets:

- P0-P4 local data processing chain.
- P5 Iceberg publishing method.
- P9/P10 non-leakage feature engineering and parity checks.
- Kafka/Flink SQL templates and realtime scoring field design.
- `cluster_ssh.py` remote execution framework.
- P12 query validation approach.
- P13 lightweight BI package generation approach.
- P14/P18 lightweight validation and packaging boundaries.

Reuse means reusing processing capability, execution framework and validation method. It does not mean reusing V1 conclusions as V2 results.

### 12. Excluded from the V2 Main Line

| Item | Reason |
| --- | --- |
| Doris | Kept as a V1 historical component. V2 display uses ClickHouse |
| OpenSearch | Backup component, not a replacement for Elasticsearch |
| Deequ / Soda | Backup quality components, not replacements for Great Expectations |
| Debezium / Kafka Connect | Possible future CDC enhancement, not the default main flow |
| Kibana / OpenSearch Dashboards | Current display package uses static BI materials |
| Three-node ClickHouse | Single-node validation is retained under the current resource boundary |
| Starting all components together | Conflicts with the low-memory modular runtime strategy |

### 13. Current Conclusion

The V2 direction is to build an independent finance-optimized evidence chain around transaction risk, account state, investigation search, quality governance and BI queries on top of the already validated V1 workflow.

Future work should keep documentation and code public-display ready, and validate optional enhancements as independent stages instead of rerunning or rewriting the accepted V2 main chain.

