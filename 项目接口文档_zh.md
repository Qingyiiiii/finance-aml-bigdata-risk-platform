# 金融大数据项目接口文档

Language: [中文](项目接口文档_zh.md) | [English](Project-Interface-Documentation_en.md)

最近更新：2026-07-03

本文件定义项目的环境、数据、脚本、表、实时流、查询层和验收接口。它面向公开仓库复现和展示，所有路径均使用仓库相对路径或通用集群路径。

## 1. 环境接口

| 项 | 值 |
| --- | --- |
| 本地项目根 | `<repo-root>` |
| 本地数据目录 | `datas/` |
| 本地配置 | `config/finance_bigdata.local.yaml` |
| 集群配置 | `config/finance_bigdata.cluster.yaml` |
| Linux 项目路径 | `/home/common/tmp/finance_bigdata_project` |
| HDFS 项目路径 | `/lakehouse/projects/finance_bigdata` |
| V1 输出目录 | `data/finance_bigdata` |
| V2 输出目录 | `data/finance_bigdata_v2` |
| Spark catalog / namespace | `lakehouse.finance_bigdata` |
| Trino catalog / schema | `iceberg.finance_bigdata` |
| Kafka topic prefix | `finance` |
| Redis key prefix | `finance_bigdata` |
| V2 ClickHouse database | `finance_bigdata_v2` |
| V2 Elasticsearch index | `finance-risk-events-v2` |

## 2. 数据接口

默认原始文件：

| 文件 | 用途 |
| --- | --- |
| `datas/HI-Small_Trans.csv` | 交易明细输入 |
| `datas/HI-Small_accounts.csv` | 账户维表输入 |
| `datas/HI-Small_Patterns.txt` | AML pattern 参考输入 |

核心字段：

| 字段组 | 含义 | 消费阶段 |
| --- | --- | --- |
| `Timestamp` | 交易发生时间 | P1、P3、P4、P9、P11 |
| `From Bank` / `To Bank` | 付款和收款银行 | P3、P4、P9、P11 |
| `Account` | 账户标识 | P3、P4、P11v2 |
| `Amount Paid` / `Amount Received` | 交易金额 | P1、P4、P9、P11 |
| `Payment Currency` / `Receiving Currency` | 币种 | P3、P4、P11 |
| `Payment Format` | 支付方式 | P4、P9 |
| `Is Laundering` | 合成标签 | P1、P9、P16 |

默认验证范围为 `HI-Small`。`Medium` 和 `Large` 不进入默认公开验收。

## 3. 本地离线接口

| 阶段 | 脚本 | 输入 | 输出 |
| --- | --- | --- | --- |
| P0 | `src/00_finance_preflight.py` | config、原始文件 | `preflight_report.md`、`summary.tsv` |
| P1 | `src/01_finance_profile.py` | 原始交易和账户文件 | `profile_summary.md`、`profile_metrics.tsv` |
| P2 | `src/02_finance_ods_sample.py` | 交易 CSV | ODS 样本和 schema 摘要 |
| P3 | `src/03_finance_dwd_build.py` | 原始交易和账户文件 | DWD 交易、账户、事件长表 |
| P4 | `src/04_finance_dws_risk_kpi.py` | P3 DWD 输出 | DWS 风险 KPI 和候选明细 |

本地编排入口：

```powershell
powershell -ExecutionPolicy Bypass -File .\bin\p0_p2_local_smoke.ps1
powershell -ExecutionPolicy Bypass -File .\bin\p3_p4_local_build.ps1
```

默认输出模式：

```text
data/finance_bigdata/runs/p0_preflight_*/
data/finance_bigdata/runs/p1_profile_*/
data/finance_bigdata/runs/p2_ods_sample_*/
data/finance_bigdata/runs/p3_dwd_build_*/
data/finance_bigdata/runs/p4_dws_risk_kpi_*/
```

## 4. 湖仓发布接口

| 脚本 | 职责 |
| --- | --- |
| `bin/p5_cluster_publish.sh` | 将 P3/P4 Parquet 输出发布到 Iceberg |
| `bin/p7_cluster_readiness_snapshot.sh` | 检查基础服务、表、topic、cache 和本地证据 |
| `bin/cluster_ssh.py` | 远程命令、上传和下载证据的通用执行器 |

核心 Iceberg 表：

| 表 | 说明 |
| --- | --- |
| `dwd_finance_transactions` | 交易明细 |
| `dwd_finance_accounts` | 账户维表 |
| `dwd_finance_transaction_events` | 借贷双边事件长表 |
| `dws_minute_transaction_kpi` | 分钟级交易 KPI |
| `dws_account_risk_features` | 账户风险画像 |
| `dws_payment_format_kpi` | 支付方式 KPI |
| `dws_large_transaction_candidates` | 大额交易候选 |

## 5. 实时链路接口

| 链路 | 文件 | 职责 |
| --- | --- | --- |
| P6 | `streaming/finance_make_replay_sample.py` | 从 DWD 生成 Kafka replay 样本 |
| P6 | `streaming/finance_risk_rules_flink.sql` | Flink 规则风险输出 |
| P6 | `streaming/finance_collect_risk_to_redis.py` | 风险事件校验并写入 Redis |
| P11 | `streaming/finance_make_scoring_contract_sample.py` | 评分契约样本生成 |
| P11 | `streaming/finance_scoring_contract_flink.sql` | 实时评分规则 SQL |
| P11 | `streaming/finance_collect_contract_to_redis.py` | P11 风险事件校验和 cache 写入 |
| P11v2 | `streaming/finance_make_p11v2_state_sample.py` | V2 风险事件样本生成 |
| P11v2 | `streaming/finance_p11v2_state_flink.sql` | V2 状态评分 SQL |
| P11v2 | `streaming/finance_collect_p11v2_state.py` | Redis cache 与 HBase durable state 写入 |

本地编排入口：

```powershell
powershell -ExecutionPolicy Bypass -File .\bin\p11_local_realtime_scoring_contract.ps1
powershell -ExecutionPolicy Bypass -File .\bin\p11v2_local_realtime_state.ps1
```

V2 实时状态边界：

- Redis 是 latest-state cache。
- HBase 是 durable account risk state。
- Flink SQL 规则分数是可解释规则评分，不是生产模型概率。
- P11v2 不依赖 ClickHouse、Elasticsearch 或 BI 包作为主验收条件。

## 6. 查询与展示接口

| 阶段 | 入口 | 输出 |
| --- | --- | --- |
| P12 | `bin/p12_local_query_layer_validation.ps1` | Trino 表计数、业务查询和 Doris 历史 smoke |
| P13 | `bin/p13_build_bi_dashboard_package.ps1` | V1 静态 BI 材料包 |
| P12v2 | `bin/p12v2_local_clickhouse_es_validation.ps1` | ClickHouse ADS 查询和 Elasticsearch 检索结果 |
| P12v2 reference | `bin/p12v2_local_query_investigation.ps1` | Trino + ClickHouse + Elasticsearch 组合参考 |
| P13v2 | 静态材料包生成 | ClickHouse-backed BI package |

V2 查询层职责：

| 组件 | 职责 |
| --- | --- |
| Trino | Iceberg 事实表交叉查询 |
| ClickHouse | ADS/BI 展示查询 |
| Elasticsearch | 风险事件调查检索 |
| OpenSearch | 备用组件，不进入主验收 |

## 7. AI 与质量接口

| 阶段 | 入口 | 说明 |
| --- | --- | --- |
| P9 | `bin/p9_local_model_baseline.ps1` | EDA、特征样本、baseline model |
| P10 | `bin/p10_local_feature_parity.ps1` | Iceberg 派生特征与本地特征一致性 |
| P16 | `bin/p16_local_ai_learning.ps1` | 模型解释和异常检测实验 |
| P17 | `bin/p17_data_quality_check.ps1` | V1 本地质量规则检查 |
| P17v2 | `bin/p17v2_local_gx_quality_check.ps1` | V2 Great Expectations 质量门禁 |

边界：P9/P16 是实验和解释性分析，不作为生产 AML 模型；P17v2 读取 V2 accepted evidence，不重跑业务链路。

## 8. 验收接口

| 阶段 | 入口 | 结论来源 |
| --- | --- | --- |
| P14 | `bin/p14_finance_master_validation.ps1` | `summary.tsv`、`phase_evidence_status.tsv`、`boundary_scan.tsv` |
| P15 | `bin/p15_local_restart_readiness.ps1` | `component_status.tsv`、`table_counts.tsv`、`realtime_restart_status.tsv` |
| P18 | `bin/p18_build_portfolio_final_package.ps1` | `p18_status.tsv`、展示入口和包边界扫描 |
| P14v2 | `bin/p14v2_master_validation.ps1` | V2 evidence matrix、component validation、boundary scan |
| P18v2 | `bin/p18v2_build_portfolio_final_package.ps1` | V2 display package、manifest、package boundary scan |

正式结论只读取对应运行目录中的状态表、摘要、矩阵和边界扫描；smoke 结果不能替代 P14/P14v2 总验收。

## 9. 配置接口

| 文件 | 关键字段 |
| --- | --- |
| `config/finance_bigdata.local.yaml` | `paths.raw_dir`、`paths.output_dir`、`processing.sample_rows`、`namespace.*` |
| `config/finance_bigdata.cluster.yaml` | `paths.linux_project_root`、`paths.hdfs_root`、`namespace.*`、`publish.*` |

公开仓库配置只保存可复现的模板参数。连接集群所需的敏感值应放在本地私有配置中，脚本输出不得回写到普通文档。

## 10. 展示安全边界

- 使用仓库相对路径描述本地输入和输出。
- 集群路径只保留通用项目路径和服务路径。
- 展示包只包含小型 Markdown、TSV、JSON、HTML 证据。
- 原始大文件、运行日志、大型明细数据和本地敏感配置不进入公开包。
- V1、V2、备用组件和历史组件的职责必须分开描述。

