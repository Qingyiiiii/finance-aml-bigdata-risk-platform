# Finance Big Data Additional Configuration

Language: [中文](金融大数据额外配置_zh.md) | [English](Finance-Big-Data-Additional-Configuration_en.md)

Last updated: 2026-07-03

This file records V2 component configuration, deployment locations, ports, runtime boundaries and public display wording for the finance big-data platform. It keeps only public configuration summaries and does not record real sensitive values, local environment paths or long installation logs.

### 1. Configuration Goals

V2 component configuration supports the following goals:

- Realtime transaction risk scoring.
- Recoverable account risk state.
- Low-latency OLAP/BI queries.
- Risk event investigation search.
- Repeatable data quality gates.
- Minimal governance, metadata and monitoring evidence.
- On-demand startup and release of heavy components in a low-memory virtual-machine environment.

### 2. V2 Component Composition

| Layer | Component | V2 Responsibility | Current Scope |
| --- | --- | --- | --- |
| event entry | Kafka | Transaction events, scoring requests and risk event topics | retained |
| realtime compute | Flink | Rule scoring, windows and event-time processing | retained |
| state cache | Redis | latest-state cache | demoted to cache |
| durable state | HBase + ZooKeeper | durable account risk state | V2 core addition |
| offline lakehouse | HDFS + Hive Metastore + Iceberg + Spark | Long-term fact tables, batch processing and feature work | retained |
| mutable lakehouse | Hudi | Supplement for upsert/CDC state tables | optional enhancement |
| interactive query | Trino | Cross-table queries over Iceberg/Hudi | retained |
| OLAP display | ClickHouse | ADS/BI query acceleration | V2 main display layer |
| investigation search | Elasticsearch | Risk event search and alert investigation | V2 main search layer |
| backup search | OpenSearch | Backup for Elasticsearch | excluded from main validation |
| data quality | Great Expectations | V2 main quality gate | primary |
| backup quality | Deequ / Soda | Spark/SQL quality experiments | excluded from main validation |
| governance metadata | Ranger + Atlas | Permission audit, metadata and lineage boundary | minimal validation |
| monitoring | Prometheus + Grafana | Component metrics and recovery checks | lightweight retained |

### 3. Version Matrix

| Component | Version Scope |
| --- | --- |
| Hadoop | `3.4.2` |
| Hive | `3.1.3` |
| Spark | `3.5.8` |
| Flink | `1.20.3` |
| Kafka | `4.1.2` |
| Iceberg | `1.11.0` |
| PostgreSQL | `15` |
| Redis | `7` |
| Trino | `481` |
| Flink CDC | `3.6.0 for Flink 1.20` |
| ClickHouse | `26.6.1.1193` |
| ZooKeeper | `3.9.5` |
| HBase | `2.6.6-hadoop3` |
| Elasticsearch | `9.4.3` |
| Great Expectations | `1.18.2` |
| Hudi | `1.2.0` bundle for Spark 3.5 |
| OpenSearch | `3.6.0` |
| Deequ | `3.0.3-spark-3.5` |
| Soda | `4.16.0` |
| Ranger | `2.6.0` |
| Atlas | `2.5.0` |
| Prometheus | `3.5.x` |
| Grafana | `13.x` |

Versions describe the current validation scope. Future upgrades require rerunning the corresponding readiness and validation scripts.

### 4. Deployment Locations

| Component | Suggested Node | Software Location | Data Location | Notes |
| --- | --- | --- | --- | --- |
| Hadoop | three nodes | `/export/server/hadoop` | HDFS | base storage and YARN |
| Hive | hadoop1 | `/export/server/hive` | PostgreSQL metastore | Iceberg catalog dependency |
| Spark | three nodes | `/export/server/spark` | HDFS / local temp | offline processing and publishing |
| Kafka | three nodes | `/export/server/kafka` | `/export/data/kafka` | KRaft mode |
| Flink | three nodes | `/export/server/flink` | `/export/logs/flink` | realtime scoring |
| Redis | hadoop1 | system package | local service data | latest-state cache |
| Trino | three nodes | `/export/server/trino` | `/export/data/trino` | Iceberg query |
| ClickHouse | hadoop1 | package default | `/export/data/clickhouse` | V2 BI queries |
| ZooKeeper | three nodes | `/export/server/zookeeper` | `/export/data/zookeeper` | HBase dependency |
| HBase | three nodes | `/export/server/hbase` | `/lakehouse/services/hbase` | V2 state storage |
| Elasticsearch | hadoop1 | `/export/server/elasticsearch` | `/export/data/elasticsearch` | risk event search |
| Great Expectations | hadoop1 | `/export/server/venv/great_expectations` | V2 quality output | no resident service |
| Hudi | three nodes | Spark jars / package directory | HDFS project path | no resident service |
| OpenSearch | hadoop1 | `/export/server/opensearch` | `/export/data/opensearch` | backup, stopped by default |
| Deequ | hadoop1 | `/export/packages/deequ` | experiment output | backup |
| Soda | hadoop1 | `/export/server/venv/soda` | experiment output | backup |
| Ranger | hadoop1 | `/export/server/ranger-admin` | PostgreSQL metadata | minimal governance validation |
| Atlas | hadoop1 | `/export/server/atlas` | `/export/data/atlas` | metadata and lineage |
| Prometheus | hadoop1 | `/export/server/prometheus` | `/export/data/prometheus` | lightweight monitoring |
| Grafana | hadoop1 | `/export/server/grafana` | local storage | lightweight dashboard |

### 5. Network and Ports

| Component | Port | Purpose | Public Scope |
| --- | ---: | --- | --- |
| HDFS NameNode | 8020 / 9870 | RPC / Web UI | base platform |
| YARN | 8088 / 8042 | ResourceManager / NodeManager | base platform |
| Hive Metastore | 9083 | catalog service | base platform |
| HiveServer2 | 10000 | SQL service | on demand |
| Kafka | 9092 / 9093 | broker / controller | realtime flow |
| Redis | 6379 | cache | hadoop1 local or internal network |
| Flink | 8081 / 6123-6127 | UI / cluster RPC | realtime flow |
| Trino | 8080 | coordinator / worker | query layer |
| ClickHouse | 8123 / 9000 | HTTP / native | V2 query display |
| ZooKeeper | 2181 / 2888 / 3888 | client / quorum | HBase dependency |
| HBase | 16000 / 16010 / 16020 / 16030 | Master / RegionServer | V2 state storage |
| Elasticsearch | 9200 / 9300 | REST / transport | V2 search layer |
| OpenSearch | 19200 / 19300 | backup REST / transport | backup, stopped by default |
| Ranger | 6080 | governance UI/API | minimal governance |
| Atlas | 21000 | metadata UI/API | minimal governance |
| Prometheus | 9090 | metrics UI/API | lightweight monitoring |
| Grafana | 3000 | dashboard UI | lightweight monitoring |

Network strategy:

- New services should bind to internal addresses or loopback first.
- Embedded helper processes should prefer `127.0.0.1`.
- Only display, query or monitoring entry points should expose required internal ports.
- Port changes must be synchronized to `Modular-Startup-Example_en.md` and readiness scripts.

### 6. Modular Runtime Strategy

V2 does not require all components to run at the same time in a low-memory environment.

| Runtime Goal | Start Components | Release Components |
| --- | --- | --- |
| offline lakehouse | HDFS, YARN, PostgreSQL, Hive Metastore and Spark | Kafka, Flink, ClickHouse, Elasticsearch, governance and monitoring |
| realtime state | HDFS, YARN, Hive Metastore, Kafka, Redis, Flink, ZooKeeper and HBase | ClickHouse, Elasticsearch, Trino, governance and monitoring |
| query display | Trino, ClickHouse, Elasticsearch and Hive Metastore if needed | Kafka, Flink, HBase, governance and monitoring |
| data quality | Python venv and exported V2 evidence | all heavy components on demand |
| governance check | PostgreSQL, Ranger and Atlas | realtime and query heavy components |
| monitoring check | Prometheus, Grafana and a small number of monitored targets | Spark/Flink large jobs and query heavy components |

P15v2 uses `low_memory_sequential` as the default recovery-check scope.

### 7. Component Changes from V1 to V2

| V1 Scope | V2 Adjustment | Reason |
| --- | --- | --- |
| Redis stores latest-state | Redis is cache only, HBase stores durable state | Risk state must be recoverable and queryable |
| Doris query/display smoke | ClickHouse becomes the V2 main display layer | Better fit for transaction aggregation and BI queries |
| Local rule quality checks | Great Expectations becomes the main quality gate | Rules are repeatable and results are display-ready |
| Single static BI package | ClickHouse-backed BI package | Metric sources are clearer |
| Runtime state confirmed manually | P15v2 modular readiness | Low-memory environment needs a recoverable scope |
| Governance/monitoring as background | Minimal Ranger/Atlas/Prometheus/Grafana validation | Completes governance, metadata and observability boundaries |

### 8. Validation Matrix

| Capability | Validation Item | Pass Scope |
| --- | --- | --- |
| HBase state | account risk state is readable | row count, sample and consistency checks exist |
| Redis cache | latest-state is writable and readable | cache keys match state-writing logic |
| ClickHouse | ADS tables are queryable | row count, aggregate queries and state-table checks pass |
| Elasticsearch | risk events are searchable | index health, document count and search sample pass |
| Great Expectations | quality gate is runnable | checkpoint and rule table pass |
| Ranger / Atlas | minimal governance readiness | service access and core APIs work |
| Prometheus / Grafana | lightweight monitoring access | targets and dashboard status are available |
| P15v2 | modular recovery | startup, validation, release and postcheck pass |
| P14v2 | independent master validation | phase evidence, component validation and boundary scan pass |
| P18v2 | lightweight display package | package manifest and boundary scan pass |

### 9. Public Configuration Boundary

- This file does not record real sensitive values.
- This file does not store private configuration file paths.
- When installation or validation scripts require sensitive values, they should read them from local private configuration.
- Script output and display packages must not write sensitive values back.
- Public documents record only component responsibilities, versions, ports, deployment locations and validation boundaries.

### 10. Future Enhancements

| Enhancement | Prerequisite | Validation Method |
| --- | --- | --- |
| Debezium / Kafka Connect | CDC source tables and topic contracts are defined | independent source connector smoke |
| Hudi upsert tables | state update key and precombine field are defined | Spark upsert plus Trino read check |
| three-node ClickHouse | current single-node validation is stable | cluster table / distributed table smoke |
| Kibana or alternative dashboard | Elasticsearch query scope is stable | dashboard JSON and screenshot evidence |
| Ranger policy expansion | minimal governance validation is stable | policy API plus audit sample |
| Atlas lineage expansion | table and task metadata are stable | entity / lineage API sample |

Enhancements must be executed and validated as independent stages. They must not rewrite conclusions from the accepted V2 main chain.

