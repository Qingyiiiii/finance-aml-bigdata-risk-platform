# 金融大数据 V2 模块化启动示例

Language: [中文](模块化启动示例_zh.md) | [English](Modular-Startup-Example_en.md)

最近更新：2026-07-03

本文件给出低内存虚拟机集群下的按需启动、检查和释放顺序。目标是支撑复现和展示，而不是要求所有 V2 组件长期同时运行。

## 1. 适用环境

| 节点 | 角色 |
| --- | --- |
| `hadoop1` | NameNode、ResourceManager、Hive Metastore、Redis、Trino coordinator、ClickHouse、Elasticsearch、治理和监控入口 |
| `hadoop2` | DataNode、NodeManager、Kafka、Flink、HBase RegionServer、Trino worker |
| `hadoop3` | DataNode、NodeManager、Kafka、Flink、HBase RegionServer、Trino worker |

运行原则：

1. 先启动当前目标的最小依赖。
2. 验证完成后释放无关重组件。
3. Spark 离线任务、Flink 实时任务、查询引擎和治理组件避免无关并发。
4. 失败后先看状态和日志，再决定是否重启。
5. P15v2 默认采用 `low_memory_sequential` 顺序。

## 2. 基础检查

在 `hadoop1` 执行：

```bash
hostname
ip addr
ip route
cat /etc/hosts
df -h /
free -h
ping -c 2 hadoop1
ping -c 2 hadoop2
ping -c 2 hadoop3
ssh hadoop2 hostname
ssh hadoop3 hostname
```

三节点磁盘和内存概览：

```bash
for h in hadoop1 hadoop2 hadoop3; do
  echo "===== $h ====="
  ssh common@$h "df -hP / /home; free -h; lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT"
done
```

关键端口检查：

```bash
ss -lntp | egrep '8020|9870|8088|8042|9083|10000|9092|9093|6379|8081|8123|9000|9200|9300|6080|21000|9090|3000' || true
```

## 3. 切换场景前释放组件

```bash
/export/server/flink/bin/stop-cluster.sh 2>/dev/null || true

for h in hadoop1 hadoop2 hadoop3; do
  ssh common@$h "export JAVA_HOME=/export/server/jdk17; /export/server/kafka/bin/kafka-server-stop.sh 2>/dev/null || true"
  ssh common@$h "export JAVA_HOME=/export/server/jdk25; /export/server/trino/bin/launcher stop 2>/dev/null || true"
done

sudo systemctl stop clickhouse-server 2>/dev/null || true
sudo systemctl stop elasticsearch-finance-v2 2>/dev/null || true
sudo systemctl stop finance-ranger-admin 2>/dev/null || true
sudo systemctl stop finance-atlas 2>/dev/null || true

/export/server/hbase/bin/stop-hbase.sh 2>/dev/null || true
for h in hadoop1 hadoop2 hadoop3; do
  ssh common@$h "/export/server/zookeeper/bin/zkServer.sh stop 2>/dev/null || true"
done

pkill -f '/export/server/prometheus/prometheus' 2>/dev/null || true
pkill -f 'grafana-server' 2>/dev/null || true
```

## 4. 运行目标矩阵

| 运行目标 | 启动组件 | 建议关闭 |
| --- | --- | --- |
| 离线湖仓 | HDFS、YARN、PostgreSQL、Hive Metastore、Spark | Kafka、Flink、Redis、ClickHouse、Elasticsearch、治理、监控 |
| 实时状态 | HDFS、YARN、Hive Metastore、Kafka、Redis、Flink、ZooKeeper、HBase | ClickHouse、Elasticsearch、Trino、治理、监控 |
| HBase 回查 | HDFS、ZooKeeper、HBase | Kafka、Flink、ClickHouse、Elasticsearch、Trino、治理、监控 |
| 查询展示 | Trino、ClickHouse、Elasticsearch，必要时保留 Hive Metastore | Kafka、Flink、HBase、治理、监控 |
| 数据质量 | Python venv、已导出的 V2 证据 | 全部重组件按需关闭 |
| 治理检查 | PostgreSQL、Ranger、Atlas | 实时和查询重组件 |
| 监控检查 | Prometheus、Grafana、少量被监控目标 | Spark/Flink 大任务、查询重组件 |

## 5. 基础服务

### HDFS / YARN

```bash
start-dfs.sh
start-yarn.sh

hdfs dfsadmin -report
yarn node -list
yarn application -list -appStates RUNNING
ss -lntp | egrep '8020|9870|8088|8042' || true
```

日志：

```text
/export/server/hadoop/logs
```

### PostgreSQL

```bash
sudo systemctl start postgresql
sudo systemctl status postgresql --no-pager
ss -lntp | grep 5432 || true
sudo -u postgres psql -c "\l"
```

日志：

```text
/var/lib/pgsql/15/data/log
journalctl -u postgresql-15 --no-pager -n 100
```

### Hive Metastore

```bash
pkill -f 'HiveMetaStore|hive --service metastore|RunJar.*HiveMetaStore' 2>/dev/null || true

export JAVA_HOME=/export/server/jdk8
export HIVE_HOME=/export/server/hive
export HADOOP_HOME=/export/server/hadoop
export HIVE_CONF_DIR=/export/server/hive/conf

nohup /export/server/hive/bin/hive --service metastore \
  > /export/logs/hive/hive-metastore.out 2>&1 &

jps | grep HiveMetaStore || true
ss -lntp | grep 9083 || true
tail -n 120 /export/logs/hive/hive-metastore.out
```

## 6. 实时状态场景

### Kafka

```bash
for h in hadoop1 hadoop2 hadoop3; do
  ssh -n common@$h "bash -lc 'export JAVA_HOME=/export/server/jdk17; mkdir -p /export/logs/kafka; setsid /export/server/kafka/bin/kafka-server-start.sh /export/server/kafka/config/kraft/server.properties > /export/logs/kafka/kafka-server.out 2>&1 < /dev/null &'"
done

/export/server/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server hadoop1:9092 describe --status
/export/server/kafka/bin/kafka-topics.sh --bootstrap-server hadoop1:9092 --list
```

### Redis

```bash
sudo systemctl start redis
redis-cli -h 127.0.0.1 ping
```

### Flink

```bash
/export/server/flink/bin/start-cluster.sh
curl -I http://hadoop1:8081
/export/server/flink/bin/flink list -r
```

### ZooKeeper / HBase

```bash
for h in hadoop1 hadoop2 hadoop3; do
  ssh common@$h "/export/server/zookeeper/bin/zkServer.sh start"
done

/export/server/hbase/bin/start-hbase.sh

echo status | /export/server/hbase/bin/hbase shell -n
```

## 7. 查询展示场景

### Trino

```bash
for h in hadoop1 hadoop2 hadoop3; do
  ssh common@$h "export JAVA_HOME=/export/server/jdk25; /export/server/trino/bin/launcher start"
done

/export/server/trino/bin/trino --server hadoop1:8080 --catalog iceberg --schema finance_bigdata --execute "SHOW TABLES"
```

### ClickHouse

```bash
sudo systemctl start clickhouse-server
clickhouse-client --query "SHOW DATABASES"
clickhouse-client --query "SELECT count(*) FROM finance_bigdata_v2.ads_account_risk_features"
```

### Elasticsearch

```bash
sudo systemctl start elasticsearch-finance-v2
curl -k https://hadoop1:9200/_cluster/health
curl -k https://hadoop1:9200/finance-risk-events-v2/_count
```

认证材料应由本地私有配置提供，不写入命令样例和展示文档。

## 8. 数据质量场景

```bash
source /export/server/venv/great_expectations/bin/activate
cd /home/common/tmp/finance_bigdata_project
python bin/p17v2_cluster_gx_quality_check.py
```

检查输出：

```text
data/finance_bigdata_v2/runs/*/quality_check_results.tsv
data/finance_bigdata_v2/runs/*/gx_validation_result.json
data/finance_bigdata_v2/runs/*/gx_checkpoint_summary.tsv
```

## 9. 治理与监控场景

### Ranger / Atlas

```bash
sudo systemctl start finance-ranger-admin
sudo systemctl start finance-atlas

curl -I http://hadoop1:6080
curl -I http://hadoop1:21000
```

Ranger 账号同步服务保持按需检查，不作为默认常驻组件。

### Prometheus / Grafana

```bash
/export/server/prometheus/prometheus \
  --config.file=/export/server/prometheus/prometheus.yml \
  --storage.tsdb.path=/export/data/prometheus \
  --web.listen-address=hadoop1:9090 \
  > /export/logs/prometheus.out 2>&1 &

grafana-server --homepath /export/server/grafana \
  > /export/logs/grafana.out 2>&1 &

curl -I http://hadoop1:9090/-/ready
curl -I http://hadoop1:3000/login
```

## 10. P15v2 推荐顺序

```text
1. 基础检查
2. 释放无关重组件
3. 启动 HDFS/YARN/PostgreSQL/Hive Metastore
4. 检查 Iceberg 核心表
5. 启动 Kafka/Redis/Flink/ZooKeeper/HBase
6. 检查 P11v2 状态可读
7. 释放实时重组件
8. 启动 Trino/ClickHouse/Elasticsearch
9. 检查 P12v2 查询和检索
10. 释放查询重组件
11. 检查 Ranger/Atlas 最小 readiness
12. 检查 Prometheus/Grafana
13. 记录备用组件状态
14. 执行 postcheck，确认 YARN/Flink 无残留任务
```

本地入口：

```powershell
powershell -ExecutionPolicy Bypass -File .\bin\p15v2_local_low_memory_readiness.ps1
```

## 11. 常见问题

| 现象 | 优先检查 |
| --- | --- |
| HDFS/YARN 未恢复 | `jps`、`hdfs dfsadmin -report`、`yarn node -list` |
| Hive Metastore 不可用 | 9083 监听、PostgreSQL 状态、Hive 日志 |
| Kafka topic 不可见 | KRaft quorum、broker 日志、JDK 版本 |
| Flink UI 不可访问 | JobManager/TaskManager 进程和 8081 端口 |
| HBase 无法读表 | ZooKeeper quorum、HBase Master/RegionServer 状态 |
| ClickHouse 查询失败 | service 状态、8123/9000 端口、database/table 是否存在 |
| Elasticsearch 检索失败 | service 状态、cluster health、index count |
| GX 结果缺失 | venv、输入证据路径、Python 依赖 |
| 内存压力过高 | 释放查询、治理、实时重组件后再重试 |

## 12. 公开展示边界

- 本文件不保存真实敏感值。
- 命令样例只展示服务启动、检查和释放方式。
- 需要认证的 API 由本地私有配置注入认证材料。
- 展示包不复制运行日志、大型数据和本地私有配置。

