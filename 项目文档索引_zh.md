# 金融大数据项目文档索引

Language: [中文](项目文档索引_zh.md) | [English](Project-Documentation-Index_en.md)

最近更新：2026-07-03

本文件是公开仓库的文档导航和阶段状态总览。它只保留可展示的项目说明、脚本入口、阶段边界和运行后输出位置，不保留旧工作区路径、本地环境路径、临时工作记录或敏感配置细节。

## 1. 展示入口

| 文档 | 作用 |
| --- | --- |
| `README.md` | 中文项目入口，覆盖项目目标、架构、快速开始、阶段说明和展示边界 |
| `README_en.md` | English entry point for project scope, architecture, quick start, phase map, and public boundary |
| `项目接口文档_zh.md` | 环境、数据、脚本、表、实时、查询和验收接口 |
| `金融大数据v2版本方案_zh.md` | V2 架构方向、阶段职责、验收边界和后续扩展策略 |
| `金融大数据额外配置_zh.md` | V2 组件版本、部署位置、端口和模块化运行策略 |
| `模块化启动示例_zh.md` | 低内存集群的按需启动、检查和释放顺序 |
| `通用大数据流程配置_zh.md` | 通用大数据底座配置摘要和运维检查清单 |

## 2. 代码目录

| 路径 | 内容 |
| --- | --- |
| `src/` | P0-P4 本地离线数仓处理脚本 |
| `streaming/` | Kafka/Flink/Redis/HBase 实时链路样本和状态写入脚本 |
| `analysis/` | EDA、特征工程、baseline model、解释性和异常检测脚本 |
| `bin/` | 本地编排、集群执行、V2 安装检查、恢复检查和验收脚本 |
| `config/` | 本地和集群配置模板 |
| `Optimize/` | 优化总结和问题排查摘要 |

## 3. 运行后输出目录

以下目录由脚本运行后生成，公开仓库不要求默认包含完整数据和证据包。

| 输出目录 | 说明 |
| --- | --- |
| `data/finance_bigdata/runs/` | V1 阶段运行结果 |
| `data/finance_bigdata/delivery_packages/` | V1 阶段交付包 |
| `data/finance_bigdata/bi_packages/` | V1 BI 材料包 |
| `data/finance_bigdata/portfolio_packages/` | V1 轻量展示包 |
| `data/finance_bigdata_v2/runs/` | V2 阶段运行结果 |
| `data/finance_bigdata_v2/bi_packages/` | V2 ClickHouse-backed BI 材料包 |
| `data/finance_bigdata_v2/portfolio_packages/` | V2 轻量展示包 |

输出目录应只保存可复盘的小型证据文件。原始大文件、Parquet 明细、大型 bulk 文件、运行日志和本地敏感配置不进入展示包。

## 4. V1 阶段总览

| 阶段 | 状态口径 | 主要产物 |
| --- | --- | --- |
| P0 | 原始文件和字段预检 | `preflight_report.md`、`summary.tsv` |
| P1 | 原始数据画像 | 标签、金额、时间、账户和交易分布摘要 |
| P2 | ODS 样本 | 类型化交易样本和 schema 摘要 |
| P3 | DWD 明细层 | 交易明细、账户维表、交易事件长表 |
| P4 | DWS 风险指标层 | 分钟 KPI、账户风险画像、支付方式 KPI、大额候选 |
| P5 | Iceberg 湖仓发布 | Hive Metastore / Iceberg 表行数校验 |
| P6 | 实时风控小闭环 | Kafka replay、Flink 规则评分、Redis latest-state |
| P7 | readiness snapshot | 基础服务、表、topic、cache 和证据状态 |
| P8 | 轻量交付包 | P0-P7 小型证据导航 |
| P9 | baseline model | 非泄漏特征、训练指标、模型卡 |
| P10 | 特征一致性 | 本地特征与 Iceberg 派生特征对齐 |
| P11 | 实时评分契约 | 输入/输出 schema、Flink 评分、Redis 写入 |
| P12 | 查询层验证 | Trino 查询和 Doris 历史 smoke |
| P13 | BI 材料包 | 指标目录、SQL 参考、静态预览 |
| P14 | 独立总验收 | 阶段证据表、关键指标表、边界扫描 |
| P15 | 重启恢复 readiness | 基础服务、实时服务和 Iceberg 表恢复检查 |
| P16 | AI 增强实验 | 模型解释、异常检测、特征组摘要 |
| P17 | 数据质量检查 | 质量规则和检查结果 |
| P18 | 最终展示包 | 展示入口、演示清单、小型证据导航 |

V1 的职责是证明端到端链路可以跑通。V2 不覆盖 V1 结果，而是在独立输出目录中完成金融优化版验证。

## 5. V2 阶段总览

| 阶段 | 当前口径 | 代表性输出 |
| --- | --- | --- |
| P11v2 | Redis cache + HBase durable account state | `p11v2_state_summary.tsv`、`risk_events_raw.jsonl`、`hbase_readback_sample.tsv` |
| P12v2 | ClickHouse ADS 查询 + Elasticsearch 调查检索 | `clickhouse_query_results.tsv`、`elasticsearch_index_status.tsv`、`elasticsearch_search_sample.json` |
| P13v2 | 静态 ClickHouse-backed BI 材料包 | `dashboard_index.md`、`dashboard_preview.html`、`dashboard_metric_catalog.md` |
| P15v2 | `low_memory_sequential` 模块化恢复 readiness | `p15v2_status.tsv`、`memory_guard.tsv`、`release_actions.tsv` |
| P17v2 | Great Expectations 数据质量门禁 | `quality_check_results.tsv`、`gx_validation_result.json`、`quality_rule_catalog.md` |
| P14v2 | V2 独立总验收 | `v2_validation_matrix.tsv`、`component_validation.tsv`、`boundary_scan.tsv` |
| P18v2 | V2 轻量展示包 | `portfolio_index.md`、`accepted_evidence_manifest.tsv`、`package_boundary_scan.tsv` |

V2 主链路：

```text
Kafka / Flink
  -> Redis cache
  -> HBase durable account state
  -> ClickHouse ADS / BI
  -> Elasticsearch investigation search
  -> Great Expectations quality gate
  -> P14v2 master validation
  -> P18v2 display package
```

## 6. 关键技术口径

| 主题 | 展示口径 |
| --- | --- |
| Redis | latest-state cache，不作为 V2 风险状态事实源 |
| HBase | 保存可恢复、可回查的账户风险状态 |
| ClickHouse | V2 OLAP/BI 展示层 |
| Elasticsearch | V2 风险事件调查检索层 |
| Doris | V1 查询层历史组件，不进入 V2 主验收 |
| OpenSearch | 备用组件，不进入 V2 主验收 |
| Great Expectations | V2 主数据质量门禁 |
| Deequ / Soda | 备用质量组件，不进入 V2 主验收 |
| Ranger / Atlas | 最小治理和元数据验收边界 |
| Prometheus / Grafana | 轻量监控入口和 readiness 参考 |

## 7. 公开边界

- 公开仓库只保留可展示文档、源码、脚本和配置模板。
- 本地敏感值、原始大文件、运行日志和大型明细数据不得提交。
- V1 与 V2 输出目录保持隔离。
- 不把 V1 的历史结论改写成 V2 结论。
- 不把实验模型描述为生产级 AML 模型。
- 不把备用组件描述成主链路组件。
- 长篇安装日志和故障操作记录应压缩为版本、端口、部署位置、检查命令和已知边界。

## 8. 维护规则

1. 新增阶段脚本时，先更新 `项目接口文档_zh.md` 的脚本接口，再更新本文件的阶段总览。
2. 新增 V2 组件时，先更新 `金融大数据额外配置_zh.md` 的组件表和端口表，再更新 `模块化启动示例_zh.md`。
3. 任何展示包只复制小型 Markdown、TSV、JSON、HTML 材料。
4. 对外文档使用仓库相对路径，不使用个人机器路径。
5. 公开文档中不写入本地敏感配置值、登录材料或临时调试记录。

