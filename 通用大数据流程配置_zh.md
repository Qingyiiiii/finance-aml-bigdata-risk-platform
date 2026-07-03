# 通用大数据流程配置

Language: [中文](通用大数据流程配置_zh.md) | [English](General-Big-Data-Process-Configuration_en.md)

最近更新：2026-07-03

本文件记录金融大数据项目使用的大数据平台底座。它是公开展示版配置摘要，保留架构、版本、路径、服务顺序、检查命令和常见问题，不保留本地下载路径、临时迁移记录、敏感配置值或长篇故障流水账。

## 1. 平台目标

平台用于支撑以下项目能力：

- 本地 AML 数据处理后发布到湖仓。
- Spark / Hive / Iceberg 提供批处理和事实表。
- Kafka / Flink / Redis / HBase 提供实时风险链路和账户状态。
- Trino / ClickHouse / Elasticsearch 提供查询、BI 和调查检索。
- Great Expectations、Ranger、Atlas、Prometheus、Grafana 提供质量、治理和监控边界。

## 2. 集群拓扑

| 节点 | 主要职责 |
| --- | --- |
| `hadoop1` | NameNode、ResourceManager、Hive Metastore、Redis、Trino coordinator、ClickHouse、Elasticsearch、治理和监控入口 |
| `hadoop2` | DataNode、NodeManager、Kafka、Flink、HBase RegionServer、Trino worker |
| `hadoop3` | DataNode、NodeManager、Kafka、Flink、HBase RegionServer、Trino worker |

通用目录：

| 路径 | 作用 |
| --- | --- |
| `/export/server` | 软件安装目录 |
| `/export/data` | 服务数据目录 |
| `/export/packages` | 离线安装包目录 |
| `/export/logs` | 运行日志目录 |
| `/lakehouse/projects/finance_bigdata` | 金融项目 HDFS 路径 |
| `/home/common/tmp/finance_bigdata_project` | 集群侧项目目录 |

## 3. 版本矩阵

| 层级 | 组件 | 版本口径 |
| --- | --- | --- |
| OS | Rocky Linux | 9.x |
| Java | JDK 8 / 17 / 25 | Hive 使用 JDK 8，Kafka/Flink/Hadoop 使用 JDK 17，Trino 使用 JDK 25 |
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

## 4. 网络端口

| 服务 | 端口 | 说明 |
| --- | ---: | --- |
| HDFS RPC | 8020 | NameNode RPC |
| HDFS UI | 9870 | NameNode UI |
| YARN RM | 8088 | ResourceManager UI |
| YARN NM | 8042 | NodeManager UI |
| Hive Metastore | 9083 | catalog service |
| HiveServer2 | 10000 | SQL service，按需启动 |
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

网络原则：内网服务只绑定内网或 loopback；只有展示、查询和监控入口开放必要端口。

## 5. 环境变量

建议将常用环境变量集中放在 `/etc/profile.d/bigdata.sh`：

```bash
export HADOOP_HOME=/export/server/hadoop
export HIVE_HOME=/export/server/hive
export SPARK_HOME=/export/server/spark
export FLINK_HOME=/export/server/flink
export KAFKA_HOME=/export/server/kafka
export TRINO_HOME=/export/server/trino
export HBASE_HOME=/export/server/hbase
export HADOOP_CONF_DIR=/export/server/hadoop/etc/hadoop
export PATH=$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$HIVE_HOME/bin:$SPARK_HOME/bin:$FLINK_HOME/bin:$KAFKA_HOME/bin:$PATH
```

不同组件需要不同 JDK 时，在启动脚本中显式设置 `JAVA_HOME`，不要依赖当前 shell 的残留值。

## 6. 基础启动顺序

```text
1. 检查三节点网络、磁盘和内存
2. 启动 HDFS
3. 启动 YARN
4. 启动 PostgreSQL
5. 启动 Hive Metastore
6. 按目标启动 Spark、Kafka、Flink、Redis、HBase、Trino、ClickHouse、Elasticsearch
7. 执行阶段脚本
8. 下载或归档轻量证据
9. 释放无关重组件
10. 执行 postcheck
```

基础检查：

```bash
hostname
ip addr
free -h
df -h /
hdfs dfsadmin -report
yarn node -list
ss -lntp | egrep '8020|9870|8088|8042|9083|9092|6379|8081|8080|8123|9200' || true
```

## 7. Hadoop / YARN

启动：

```bash
start-dfs.sh
start-yarn.sh
```

检查：

```bash
jps
hdfs dfsadmin -report
hdfs dfs -ls /
yarn node -list
yarn application -list -appStates RUNNING
```

验收口径：

- NameNode 可访问。
- DataNode 数量符合三节点预期。
- ResourceManager 可访问。
- NodeManager 全部注册。
- 阶段结束后无异常残留应用。

## 8. PostgreSQL / Hive

PostgreSQL：

```bash
sudo systemctl start postgresql
sudo systemctl status postgresql --no-pager
sudo -u postgres psql -c "\l"
```

Hive Metastore：

```bash
export JAVA_HOME=/export/server/jdk8
nohup /export/server/hive/bin/hive --service metastore \
  > /export/logs/hive/hive-metastore.out 2>&1 &

ss -lntp | grep 9083 || true
```

HiveServer2 只在需要 Beeline SQL 验证时启动，常态不要求运行。

## 9. Spark / Iceberg

Spark 负责本地 Parquet 输出的集群发布、Iceberg 表写入和特征派生。

典型检查：

```bash
spark-submit --version
spark-sql --master yarn --conf spark.sql.catalog.lakehouse=org.apache.iceberg.spark.SparkCatalog
```

Iceberg 表应通过 Spark 和 Trino 交叉查询验证：

```sql
SHOW TABLES IN lakehouse.finance_bigdata;
SELECT count(*) FROM lakehouse.finance_bigdata.dws_account_risk_features;
```

## 10. Kafka / Flink / Redis

Kafka：

```bash
for h in hadoop1 hadoop2 hadoop3; do
  ssh common@$h "export JAVA_HOME=/export/server/jdk17; /export/server/kafka/bin/kafka-server-start.sh -daemon /export/server/kafka/config/kraft/server.properties"
done

/export/server/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server hadoop1:9092 describe --status
/export/server/kafka/bin/kafka-topics.sh --bootstrap-server hadoop1:9092 --list
```

Redis：

```bash
sudo systemctl start redis
redis-cli -h 127.0.0.1 ping
```

Flink：

```bash
/export/server/flink/bin/start-cluster.sh
curl -I http://hadoop1:8081
/export/server/flink/bin/flink list -r
```

阶段结束后检查：

```bash
/export/server/flink/bin/flink list -r
yarn application -list -appStates RUNNING
```

## 11. Trino

启动：

```bash
for h in hadoop1 hadoop2 hadoop3; do
  ssh common@$h "export JAVA_HOME=/export/server/jdk25; /export/server/trino/bin/launcher start"
done
```

检查：

```bash
/export/server/trino/bin/trino --server hadoop1:8080 --execute "SHOW CATALOGS"
/export/server/trino/bin/trino --server hadoop1:8080 --catalog iceberg --schema finance_bigdata --execute "SHOW TABLES"
```

Iceberg catalog 需要显式启用 HDFS 文件系统支持，否则可能只能列库表但不能读取 metadata/data 文件。

## 12. ClickHouse

启动：

```bash
sudo systemctl start clickhouse-server
```

检查：

```bash
clickhouse-client --query "SHOW DATABASES"
clickhouse-client --query "SHOW TABLES FROM finance_bigdata_v2"
clickhouse-client --query "SELECT count(*) FROM finance_bigdata_v2.ads_account_risk_features"
```

边界：ClickHouse 是 V2 OLAP/BI 展示层，不是长期事实源。

## 13. ZooKeeper / HBase

ZooKeeper：

```bash
for h in hadoop1 hadoop2 hadoop3; do
  ssh common@$h "/export/server/zookeeper/bin/zkServer.sh start"
  ssh common@$h "/export/server/zookeeper/bin/zkServer.sh status"
done
```

HBase：

```bash
/export/server/hbase/bin/start-hbase.sh
/export/server/hbase/bin/hbase shell -n <<'EOF'
status
list_namespace
EOF
```

边界：HBase 是 V2 durable account risk state，不替代 Iceberg 事实表。

## 14. Elasticsearch

启动：

```bash
sudo systemctl start elasticsearch-finance-v2
```

检查：

```bash
curl -k https://hadoop1:9200/_cluster/health
curl -k https://hadoop1:9200/finance-risk-events-v2/_count
```

认证材料由本地私有配置提供，不写入普通文档。Elasticsearch 是 V2 调查检索副本，不是事实源。

## 15. Great Expectations

运行方式：

```bash
source /export/server/venv/great_expectations/bin/activate
cd /home/common/tmp/finance_bigdata_project
python bin/p17v2_cluster_gx_quality_check.py
```

输出：

```text
data/finance_bigdata_v2/runs/*/quality_check_results.tsv
data/finance_bigdata_v2/runs/*/quality_rule_catalog.md
data/finance_bigdata_v2/runs/*/gx_validation_result.json
```

边界：Great Expectations 不需要常驻服务，不新增监听端口。

## 16. Ranger / Atlas

最小 readiness：

```bash
sudo systemctl start finance-ranger-admin
sudo systemctl start finance-atlas
curl -I http://hadoop1:6080
curl -I http://hadoop1:21000
```

边界：

- Ranger/Atlas 进入 V2 最小治理和元数据验收。
- 不要求全量策略、全量 hook 或账号同步链路进入默认验收。
- 验收后按模块化策略释放重组件。

## 17. Prometheus / Grafana

启动：

```bash
/export/server/prometheus/prometheus \
  --config.file=/export/server/prometheus/prometheus.yml \
  --storage.tsdb.path=/export/data/prometheus \
  --web.listen-address=hadoop1:9090 \
  > /export/logs/prometheus.out 2>&1 &

grafana-server --homepath /export/server/grafana \
  > /export/logs/grafana.out 2>&1 &
```

检查：

```bash
curl -I http://hadoop1:9090/-/ready
curl -I http://hadoop1:3000/login
```

边界：Prometheus/Grafana 是轻量监控入口，不要求在所有阶段长期运行。

## 18. 验收矩阵

| 类别 | 检查项 |
| --- | --- |
| 基础平台 | HDFS、YARN、PostgreSQL、Hive Metastore 可用 |
| 湖仓 | Iceberg 核心表存在且可被 Spark/Trino 查询 |
| 实时 | Kafka quorum、Flink cluster、Redis ping、HBase readback 正常 |
| 查询 | Trino、ClickHouse、Elasticsearch 按需可用 |
| 质量 | Great Expectations checkpoint 和规则表通过 |
| 治理 | Ranger / Atlas 最小 readiness 通过 |
| 监控 | Prometheus / Grafana 轻量检查通过 |
| 恢复 | P15v2 模块化启动、释放和 postcheck 通过 |
| 总验收 | P14/P14v2 读取阶段证据矩阵并完成边界扫描 |
| 展示 | P18/P18v2 只复制小型可读材料 |

## 19. 常见问题

| 现象 | 处理方向 |
| --- | --- |
| Kafka 报 class file version 不匹配 | 确认当前 shell 和启动脚本使用 JDK 17 |
| Hive Metastore 可启动但查询异常 | 检查 PostgreSQL、Hive 配置和 Hadoop classpath |
| Trino 能列库表但读取失败 | 检查 Iceberg catalog 的 HDFS 配置 |
| Flink SQL 任务提交后结果未落盘 | 检查 DML 同步、checkpoint、YARN application 和日志 |
| ClickHouse 端口不可达 | 检查 service 状态和 8123/9000 监听 |
| Elasticsearch API 不通 | 检查 service 状态、9200/9300 监听和本地认证配置 |
| HBase 状态不可读 | 检查 ZooKeeper quorum、HBase Master 和 RegionServer |
| 内存压力过高 | 先释放查询、治理、监控和实时重组件，再按场景重启 |
| P15v2 postcheck 有残留 | 先清理 YARN/Flink running 任务，再重新执行 readiness |

## 20. 公开展示边界

- 不在文档中写入真实敏感值。
- 不使用个人机器路径作为公开路径。
- 不把长篇安装过程当作展示材料。
- 不复制原始大文件、Parquet 明细、大型 bulk 响应或运行日志到展示包。
- V1、V2、备用组件和历史组件的职责必须分开。
- 任何组件升级、端口变更或绑定策略变化，都需要同步更新 `金融大数据额外配置_zh.md`、`模块化启动示例_zh.md` 和相关 readiness 脚本。

