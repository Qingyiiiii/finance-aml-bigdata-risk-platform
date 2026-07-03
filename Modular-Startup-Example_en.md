# Modular Startup Example

Language: [中文](模块化启动示例_zh.md) | [English](Modular-Startup-Example_en.md)

Last updated: 2026-07-03

This file provides on-demand startup, check and release order for a low-memory virtual-machine cluster. The goal is to support reproduction and display, not to require all V2 components to run at the same time for long periods.

### 1. Applicable Environment

| Node | Role |
| --- | --- |
| `hadoop1` | NameNode, ResourceManager, Hive Metastore, Redis, Trino coordinator, ClickHouse, Elasticsearch, governance and monitoring entry |
| `hadoop2` | DataNode, NodeManager, Kafka, Flink, HBase RegionServer and Trino worker |
| `hadoop3` | DataNode, NodeManager, Kafka, Flink, HBase RegionServer and Trino worker |

Runtime principles:

1. Start only the minimal dependencies required for the current target.
2. Release unrelated heavy components after validation.
3. Avoid unnecessary concurrency between Spark offline jobs, Flink realtime jobs, query engines and governance components.
4. After failure, inspect status and logs before deciding whether to restart.
5. P15v2 uses the `low_memory_sequential` order by default.

### 2. Base Checks

Run basic host, network, disk, memory and SSH checks on `hadoop1` before starting a scenario. Confirm three-node reachability, disk usage, available memory and key service ports.

Key port groups include HDFS/YARN, Hive, Kafka, Redis, Flink, ClickHouse, Elasticsearch, Ranger, Atlas, Prometheus and Grafana.

### 3. Releasing Components Before Switching Scenarios

Before switching from one scenario to another, stop unrelated heavy services such as Flink, Kafka, Trino, ClickHouse, Elasticsearch, Ranger, Atlas, HBase, ZooKeeper, Prometheus and Grafana according to the current environment state.

Release actions should be treated as operational safeguards. They are not business data processing steps and should not be used as evidence of phase completion by themselves.

### 4. Runtime Target Matrix

| Runtime Target | Start Components | Recommended Shutdown |
| --- | --- | --- |
| offline lakehouse | HDFS, YARN, PostgreSQL, Hive Metastore and Spark | Kafka, Flink, Redis, ClickHouse, Elasticsearch, governance and monitoring |
| realtime state | HDFS, YARN, Hive Metastore, Kafka, Redis, Flink, ZooKeeper and HBase | ClickHouse, Elasticsearch, Trino, governance and monitoring |
| HBase readback | HDFS, ZooKeeper and HBase | Kafka, Flink, ClickHouse, Elasticsearch, Trino, governance and monitoring |
| query display | Trino, ClickHouse, Elasticsearch and Hive Metastore if needed | Kafka, Flink, HBase, governance and monitoring |
| data quality | Python venv and exported V2 evidence | all heavy components on demand |
| governance check | PostgreSQL, Ranger and Atlas | realtime and query heavy components |
| monitoring check | Prometheus, Grafana and a small number of monitored targets | Spark/Flink large jobs and query heavy components |

### 5. Base Services

Base services include HDFS, YARN, PostgreSQL and Hive Metastore.

Validation scope:

- HDFS reports expected nodes.
- YARN reports registered NodeManagers and no unexpected running applications after the phase.
- PostgreSQL is available for metadata services.
- Hive Metastore listens on the expected port and can serve the Iceberg catalog dependency.

### 6. Realtime State Scenario

Realtime state validation starts Kafka, Redis, Flink, ZooKeeper and HBase on demand.

Validation scope:

- Kafka quorum and topic listing work.
- Redis returns PONG and stores latest-state cache data.
- Flink cluster is reachable and has no unexpected running job before or after validation.
- ZooKeeper quorum supports HBase.
- HBase can report status and read back P11v2 state evidence.

### 7. Query Display Scenario

Query display validation starts Trino, ClickHouse and Elasticsearch on demand.

Validation scope:

- Trino can query the configured Iceberg schema.
- ClickHouse can list the V2 database and query ADS tables.
- Elasticsearch cluster health and V2 index count are readable.
- Authentication material is provided by private local configuration and must not be written into command examples or display documents.

### 8. Data Quality Scenario

Great Expectations runs from a Python virtual environment and reads exported V2 evidence. It does not require a resident service and should not start the full cluster by itself.

Expected outputs:

```text
data/finance_bigdata_v2/runs/*/quality_check_results.tsv
data/finance_bigdata_v2/runs/*/gx_validation_result.json
data/finance_bigdata_v2/runs/*/gx_checkpoint_summary.tsv
```

### 9. Governance and Monitoring Scenario

Ranger and Atlas are checked through minimal service readiness and API/UI availability. Prometheus and Grafana are checked as lightweight monitoring entry points.

These components are part of V2 readiness evidence, but they do not replace business data validation or master validation.

### 10. Recommended P15v2 Order

```text
1. Run base checks
2. Release unrelated heavy components
3. Start HDFS/YARN/PostgreSQL/Hive Metastore
4. Check core Iceberg tables
5. Start Kafka/Redis/Flink/ZooKeeper/HBase
6. Check readable P11v2 state
7. Release realtime heavy components
8. Start Trino/ClickHouse/Elasticsearch
9. Check P12v2 queries and search
10. Release query heavy components
11. Check minimal Ranger/Atlas readiness
12. Check Prometheus/Grafana
13. Record backup component status
14. Run postcheck and confirm no residual YARN/Flink tasks
```

Local entry point:

```powershell
powershell -ExecutionPolicy Bypass -File .\bin\p15v2_local_low_memory_readiness.ps1
```

### 11. Common Issues

| Symptom | First Check |
| --- | --- |
| HDFS/YARN not recovered | `jps`, `hdfs dfsadmin -report`, `yarn node -list` |
| Hive Metastore unavailable | port 9083, PostgreSQL status and Hive logs |
| Kafka topic invisible | KRaft quorum, broker logs and JDK version |
| Flink UI unreachable | JobManager/TaskManager process and port 8081 |
| HBase table unreadable | ZooKeeper quorum and HBase Master/RegionServer status |
| ClickHouse query failed | service status, 8123/9000 ports and database/table existence |
| Elasticsearch search failed | service status, cluster health and index count |
| GX result missing | venv, input evidence path and Python dependencies |
| memory pressure too high | release query, governance and realtime heavy components before retrying |

### 12. Public Display Boundary

- This file does not store real sensitive values.
- Command examples only show service startup, check and release methods.
- APIs that require authentication should receive credentials from private local configuration.
- Display packages must not copy runtime logs, large data or local private configuration.

