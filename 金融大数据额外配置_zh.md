# 金融大数据额外配置

Language: [中文](金融大数据额外配置_zh.md) | [English](Finance-Big-Data-Additional-Configuration_en.md)

最近更新：2026-07-03

本文件记录 V2 金融大数据平台的组件配置、部署位置、端口、运行边界和展示口径。它只保留公开可展示的配置摘要，不记录真实敏感值、本地环境路径或长篇安装过程日志。

## 1. 配置目标

V2 组件配置围绕以下目标展开：

- 支撑实时交易风险评分。
- 保存可恢复的账户风险状态。
- 提供低延迟 OLAP/BI 查询。
- 提供风险事件调查检索。
- 建立可重复的数据质量门禁。
- 补齐最小治理、元数据和监控证据。
- 在低内存虚拟机环境中按需启动和释放重组件。

## 2. V2 组件构成

| 层级 | 组件 | V2 职责 | 当前口径 |
| --- | --- | --- | --- |
| 事件入口 | Kafka | 交易事件、评分请求、风险事件 topic | 保留 |
| 实时计算 | Flink | 规则评分、窗口、事件时间处理 | 保留 |
| 状态 cache | Redis | latest-state cache | 降级为 cache |
| 持久状态 | HBase + ZooKeeper | durable account risk state | V2 新增核心 |
| 离线湖仓 | HDFS + Hive Metastore + Iceberg + Spark | 长期事实表、批处理、特征加工 | 保留 |
| 更新型湖仓 | Hudi | upsert/CDC 型状态表补充 | 可选增强 |
| 交互查询 | Trino | Iceberg/Hudi 跨表查询 | 保留 |
| OLAP 展示 | ClickHouse | ADS/BI 查询加速 | V2 主展示层 |
| 调查检索 | Elasticsearch | 风险事件检索和告警调查 | V2 主检索层 |
| 备用检索 | OpenSearch | Elasticsearch 备用方案 | 不进入主验收 |
| 数据质量 | Great Expectations | V2 主质量门禁 | 主用 |
| 备用质量 | Deequ / Soda | Spark/SQL 质量实验 | 不进入主验收 |
| 治理元数据 | Ranger + Atlas | 权限审计、元数据和血缘边界 | 最小验收 |
| 监控 | Prometheus + Grafana | 组件指标和恢复检查 | 轻量保留 |

## 3. 版本矩阵

| 组件 | 版本口径 |
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

版本号用于说明当前验证口径。后续升级时需要重新执行对应 readiness 和验收脚本。

## 4. 部署位置

| 组件 | 建议节点 | 软件位置 | 数据位置 | 说明 |
| --- | --- | --- | --- | --- |
| Hadoop | 三节点 | `/export/server/hadoop` | HDFS | 基础存储与 YARN |
| Hive | hadoop1 | `/export/server/hive` | PostgreSQL metastore | Iceberg catalog 依赖 |
| Spark | 三节点 | `/export/server/spark` | HDFS / local temp | 离线处理与发布 |
| Kafka | 三节点 | `/export/server/kafka` | `/export/data/kafka` | KRaft 模式 |
| Flink | 三节点 | `/export/server/flink` | `/export/logs/flink` | 实时评分 |
| Redis | hadoop1 | system package | local service data | latest-state cache |
| Trino | 三节点 | `/export/server/trino` | `/export/data/trino` | 查询 Iceberg |
| ClickHouse | hadoop1 | package default | `/export/data/clickhouse` | V2 BI 查询 |
| ZooKeeper | 三节点 | `/export/server/zookeeper` | `/export/data/zookeeper` | HBase 依赖 |
| HBase | 三节点 | `/export/server/hbase` | `/lakehouse/services/hbase` | V2 状态存储 |
| Elasticsearch | hadoop1 | `/export/server/elasticsearch` | `/export/data/elasticsearch` | 风险事件检索 |
| Great Expectations | hadoop1 | `/export/server/venv/great_expectations` | V2 quality output | 无常驻服务 |
| Hudi | 三节点 | Spark jars / package dir | HDFS project path | 无常驻服务 |
| OpenSearch | hadoop1 | `/export/server/opensearch` | `/export/data/opensearch` | 备用，默认不启动 |
| Deequ | hadoop1 | `/export/packages/deequ` | experiment output | 备用 |
| Soda | hadoop1 | `/export/server/venv/soda` | experiment output | 备用 |
| Ranger | hadoop1 | `/export/server/ranger-admin` | PostgreSQL metadata | 最小治理验收 |
| Atlas | hadoop1 | `/export/server/atlas` | `/export/data/atlas` | 元数据和血缘 |
| Prometheus | hadoop1 | `/export/server/prometheus` | `/export/data/prometheus` | 轻量监控 |
| Grafana | hadoop1 | `/export/server/grafana` | local storage | 轻量 dashboard |

## 5. 网络与端口

| 组件 | 端口 | 用途 | 公开口径 |
| --- | ---: | --- | --- |
| HDFS NameNode | 8020 / 9870 | RPC / Web UI | 基础平台 |
| YARN | 8088 / 8042 | ResourceManager / NodeManager | 基础平台 |
| Hive Metastore | 9083 | catalog service | 基础平台 |
| HiveServer2 | 10000 | SQL service | 按需启动 |
| Kafka | 9092 / 9093 | broker / controller | 实时链路 |
| Redis | 6379 | cache | hadoop1 本地或内网 |
| Flink | 8081 / 6123-6127 | UI / cluster RPC | 实时链路 |
| Trino | 8080 | coordinator / worker | 查询层 |
| ClickHouse | 8123 / 9000 | HTTP / native | V2 查询展示 |
| ZooKeeper | 2181 / 2888 / 3888 | client / quorum | HBase 依赖 |
| HBase | 16000 / 16010 / 16020 / 16030 | Master / RegionServer | V2 状态存储 |
| Elasticsearch | 9200 / 9300 | REST / transport | V2 检索层 |
| OpenSearch | 19200 / 19300 | backup REST / transport | 备用，默认停止 |
| Ranger | 6080 | governance UI/API | 最小治理 |
| Atlas | 21000 | metadata UI/API | 最小治理 |
| Prometheus | 9090 | metrics UI/API | 轻量监控 |
| Grafana | 3000 | dashboard UI | 轻量监控 |

网络策略：

- 新服务优先绑定内网地址或 loopback。
- 内嵌 helper 进程优先限制在 `127.0.0.1`。
- 只有展示、查询或监控需要访问的入口才开放内网端口。
- 端口变更后必须同步 `模块化启动示例_zh.md` 和 readiness 脚本。

## 6. 模块化运行策略

低内存环境下，V2 不要求全部组件同时运行。推荐模式：

| 运行目标 | 启动组件 | 释放组件 |
| --- | --- | --- |
| 离线湖仓 | HDFS、YARN、PostgreSQL、Hive Metastore、Spark | Kafka、Flink、ClickHouse、Elasticsearch、治理、监控 |
| 实时状态 | HDFS、YARN、Hive Metastore、Kafka、Redis、Flink、ZooKeeper、HBase | ClickHouse、Elasticsearch、Trino、治理、监控 |
| 查询展示 | Trino、ClickHouse、Elasticsearch，必要时保留 Hive Metastore | Kafka、Flink、HBase、治理、监控 |
| 数据质量 | Python venv、已导出的 V2 证据 | 重组件全部按需关闭 |
| 治理检查 | PostgreSQL、Ranger、Atlas | 实时和查询重组件 |
| 监控检查 | Prometheus、Grafana、少量被检查目标 | Spark/Flink 大任务、查询重组件 |

P15v2 的 `low_memory_sequential` 模式是后续恢复检查的默认口径。

## 7. V1 到 V2 的组件变化

| V1 口径 | V2 调整 | 原因 |
| --- | --- | --- |
| Redis 承担 latest-state | Redis 只做 cache，HBase 保存 durable state | 风险状态需要可恢复和可回查 |
| Doris 作为查询展示 smoke | ClickHouse 进入 V2 主展示层 | 更贴合交易聚合和 BI 查询场景 |
| 本地规则质量检查 | Great Expectations 进入主质量门禁 | 规则可重复、结果可展示 |
| 单一静态 BI 包 | ClickHouse-backed BI 包 | 指标来源更清晰 |
| 运行后状态靠手工确认 | P15v2 模块化 readiness | 低内存环境需要可恢复口径 |
| 治理监控仅作为背景 | Ranger/Atlas/Prometheus/Grafana 最小验收 | 补齐治理、元数据和可观测性 |

## 8. 验收矩阵

| 能力 | 验收项 | 通过口径 |
| --- | --- | --- |
| HBase state | account risk state 可读 | 行数、样例和一致性检查存在 |
| Redis cache | latest-state 可写可读 | cache key 与状态写入逻辑一致 |
| ClickHouse | ADS 表可查询 | 行数、聚合查询和状态表通过 |
| Elasticsearch | 风险事件可检索 | index health、document count、search sample 通过 |
| Great Expectations | 质量门禁可运行 | checkpoint 和规则表通过 |
| Ranger / Atlas | 最小治理 readiness | 服务可访问、核心 API 正常 |
| Prometheus / Grafana | 轻量监控可访问 | targets 和 dashboard 状态正常 |
| P15v2 | 模块化恢复 | 启动、验证、释放、postcheck 均通过 |
| P14v2 | 独立总验收 | 阶段证据、组件验收、边界扫描均通过 |
| P18v2 | 轻量展示包 | 包清单和边界扫描通过 |

## 9. 公开配置边界

- 本文件不记录真实敏感值。
- 本文件不保存私有配置文件路径。
- 安装或验收脚本需要敏感值时，应从本地私有配置读取。
- 脚本输出和展示包不得回写敏感值。
- 公开文档只记录组件职责、版本、端口、部署位置和验收边界。

## 10. 后续增强建议

| 增强项 | 前置条件 | 验收方式 |
| --- | --- | --- |
| Debezium / Kafka Connect | 明确 CDC 来源表和 topic 契约 | 独立 source connector smoke |
| Hudi upsert 表 | 明确状态更新主键和 precombine 字段 | Spark upsert + Trino 读取检查 |
| 三节点 ClickHouse | 当前单节点验收稳定后 | cluster table / distributed table smoke |
| Kibana 或替代 dashboard | Elasticsearch 查询口径稳定后 | dashboard JSON 和截图证据 |
| Ranger 策略扩展 | 最小治理验收稳定后 | policy API + audit sample |
| Atlas 血缘扩展 | 表和任务元数据稳定后 | entity / lineage API sample |

增强项必须作为独立阶段执行和验收，不能改写已经通过的 V2 主链路结论。

