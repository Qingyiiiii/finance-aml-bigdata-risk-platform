# General Big Data Process Configuration

Language: [中文](通用大数据流程配置_zh.md) | [English](General-Big-Data-Process-Configuration_en.md)

Last updated: 2026-07-03

This file records the big-data platform foundation used by the finance big-data project. It is a public display configuration summary that keeps architecture, versions, paths, service order, check commands and common issues. It does not retain local download paths, temporary migration traces, sensitive configuration values or long troubleshooting logs.

### 1. Platform Goals

The platform supports the following project capabilities:

- Publish locally processed AML data to the lakehouse.
- Use Spark / Hive / Iceberg for batch processing and fact tables.
- Use Kafka / Flink / Redis / HBase for realtime risk flows and account state.
- Use Trino / ClickHouse / Elasticsearch for query, BI and investigation search.
- Use Great Expectations, Ranger, Atlas, Prometheus and Grafana for quality, governance and monitoring boundaries.

### 2. Cluster Topology

| Node | Main Responsibility |
| --- | --- |
| `hadoop1` | NameNode, ResourceManager, Hive Metastore, Redis, Trino coordinator, ClickHouse, Elasticsearch, governance and monitoring entry |
| `hadoop2` | DataNode, NodeManager, Kafka, Flink, HBase RegionServer and Trino worker |
| `hadoop3` | DataNode, NodeManager, Kafka, Flink, HBase RegionServer and Trino worker |

Common directories:

| Path | Purpose |
| --- | --- |
| `/export/server` | software installation directory |
| `/export/data` | service data directory |
| `/export/packages` | offline package directory |
| `/export/logs` | runtime log directory |
| `/lakehouse/projects/finance_bigdata` | finance project HDFS path |
| `/home/common/tmp/finance_bigdata_project` | cluster-side project directory |

### 3. Version Matrix

| Layer | Component | Version Scope |
| --- | --- | --- |
| OS | Rocky Linux | 9.x |
| Java | JDK 8 / 17 / 25 | Hive uses JDK 8, Kafka/Flink/Hadoop use JDK 17, Trino uses JDK 25 |
| Storage | Hadoop | 3.4.2 |
| Metadata | Hive | 3.1.3 |
| Compute | Spark | 3.5.8 |
| Stream | Kafka | 4.1.2 KRaft |
| Stream | Flink | 1.20.3 |
| Lakehouse | Iceberg | 1.11.0 |
| Cache | Redis | 7.x |
| SQL | Trino | 481 |
| OLAP | ClickHouse | 26.6.1.1193 |
| State | ZooKeeper / HBase | 3.9.5 / 2.6.6-hadoop3 |
| Search | Elasticsearch | 9.4.3 |
| Quality | Great Expectations | 1.18.2 |
| Governance | Ranger / Atlas | 2.6.0 / 2.5.0 |
| Monitoring | Prometheus / Grafana | 3.5.x / 13.x |

### 4. Network Ports

| Service | Port | Description |
| --- | ---: | --- |
| HDFS RPC | 8020 | NameNode RPC |
| HDFS UI | 9870 | NameNode UI |
| YARN RM | 8088 | ResourceManager UI |
| YARN NM | 8042 | NodeManager UI |
| Hive Metastore | 9083 | catalog service |
| HiveServer2 | 10000 | SQL service, started on demand |
| PostgreSQL | 5432 | metadata database |
| Kafka | 9092 / 9093 | broker / controller |
| Redis | 6379 | cache |
| Flink | 8081 / 6123-6127 | UI / cluster RPC |
| Trino | 8080 | coordinator / worker |
| ClickHouse | 8123 / 9000 | HTTP / native client |
| ZooKeeper | 2181 / 2888 / 3888 | client / quorum |
| HBase | 16000 / 16010 / 16020 / 16030 | Master / RegionServer |
| Elasticsearch | 9200 / 9300 | REST / transport |
| Ranger | 6080 | governance UI/API |
| Atlas | 21000 | metadata UI/API |
| Prometheus | 9090 | metrics UI/API |
| Grafana | 3000 | dashboard UI |

Network principle: internal services bind only to internal addresses or loopback. Only display, query and monitoring entry points expose the necessary ports.

### 5. Environment Variables

Common environment variables should be centralized in `/etc/profile.d/bigdata.sh`. Startup scripts should explicitly set `JAVA_HOME` for components that require different JDK versions and should not rely on stale shell state.

### 6. Base Startup Order

```text
1. Check three-node network, disk and memory
2. Start HDFS
3. Start YARN
4. Start PostgreSQL
5. Start Hive Metastore
6. Start Spark, Kafka, Flink, Redis, HBase, Trino, ClickHouse and Elasticsearch according to the target
7. Run phase scripts
8. Download or archive lightweight evidence
9. Release unrelated heavy components
10. Run postcheck
```

### 7. Hadoop / YARN

Validation scope:

- NameNode is accessible.
- DataNode count matches the three-node expectation.
- ResourceManager is accessible.
- All NodeManagers are registered.
- No abnormal residual applications remain after the phase.

### 8. PostgreSQL / Hive

PostgreSQL provides metadata storage. Hive Metastore provides the catalog service required by Iceberg. HiveServer2 is started only when Beeline SQL validation is needed and is not required to run by default.

### 9. Spark / Iceberg

Spark publishes local Parquet outputs to the cluster, writes Iceberg tables and derives features. Iceberg tables should be cross-validated through Spark and Trino queries.

### 10. Kafka / Flink / Redis

Kafka provides realtime topics, Flink executes rule and scoring SQL, and Redis stores latest-state cache. After each realtime phase, check that Flink and YARN do not retain unexpected running jobs.

### 11. Trino

Trino queries the Iceberg catalog and finance schema. The Iceberg catalog must explicitly enable HDFS filesystem support, otherwise Trino may list schemas/tables but fail to read metadata or data files.

### 12. ClickHouse

ClickHouse is the V2 OLAP/BI display layer. It is not the long-term source of truth.

### 13. ZooKeeper / HBase

ZooKeeper provides the HBase quorum dependency. HBase stores the V2 durable account risk state and does not replace Iceberg fact tables.

### 14. Elasticsearch

Elasticsearch stores the V2 risk-event investigation search replica. Authentication material is provided by private local configuration and must not be written into regular documents. Elasticsearch is not the source of truth.

### 15. Great Expectations

Great Expectations runs from a Python virtual environment and writes quality results under V2 run directories. It does not require a resident service and does not add a listening port.

### 16. Ranger / Atlas

Ranger and Atlas enter V2 only as minimal governance and metadata readiness checks. Full policies, full hooks or account-sync chains are not required for default validation. Heavy services should be released according to the modular strategy after validation.

### 17. Prometheus / Grafana

Prometheus and Grafana are lightweight monitoring entry points. They are not required to run throughout all phases.

### 18. Validation Matrix

| Category | Check Item |
| --- | --- |
| base platform | HDFS, YARN, PostgreSQL and Hive Metastore are available |
| lakehouse | Iceberg core tables exist and can be queried by Spark/Trino |
| realtime | Kafka quorum, Flink cluster, Redis ping and HBase readback are normal |
| query | Trino, ClickHouse and Elasticsearch are available on demand |
| quality | Great Expectations checkpoint and rule table pass |
| governance | Minimal Ranger / Atlas readiness passes |
| monitoring | Lightweight Prometheus / Grafana checks pass |
| recovery | P15v2 modular startup, release and postcheck pass |
| master validation | P14/P14v2 read phase evidence matrices and complete boundary scans |
| display | P18/P18v2 copy only small readable materials |

### 19. Common Issues

| Symptom | Handling Direction |
| --- | --- |
| Kafka reports class file version mismatch | Confirm that the current shell and startup scripts use JDK 17 |
| Hive Metastore starts but queries fail | Check PostgreSQL, Hive configuration and Hadoop classpath |
| Trino can list schemas/tables but cannot read data | Check HDFS configuration for the Iceberg catalog |
| Flink SQL job submits but output is missing | Check DML synchronization, checkpoint, YARN application and logs |
| ClickHouse port unreachable | Check service status and 8123/9000 listeners |
| Elasticsearch API unreachable | Check service status, 9200/9300 listeners and local authentication configuration |
| HBase state unreadable | Check ZooKeeper quorum, HBase Master and RegionServer |
| memory pressure too high | Release query, governance, monitoring and realtime heavy components before restarting by scenario |
| P15v2 postcheck has residual tasks | Clean YARN/Flink running tasks before rerunning readiness |

### 20. Public Display Boundary

- Do not write real sensitive values into documents.
- Do not use personal machine paths as public paths.
- Do not treat long installation procedures as display materials.
- Do not copy raw large files, Parquet detail files, large bulk responses or runtime logs into display packages.
- V1, V2, backup components and historical components must be described separately.
- Any component upgrade, port change or binding-strategy change must be synchronized to `Finance-Big-Data-Additional-Configuration_en.md`, `Modular-Startup-Example_en.md` and related readiness scripts.

