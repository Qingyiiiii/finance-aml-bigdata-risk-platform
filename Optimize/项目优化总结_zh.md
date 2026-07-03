# 金融大数据项目优化总结

Language: [中文](项目优化总结_zh.md) | [English](Project-Optimization-Summary_en.md)

本文档记录每个阶段的目标、已沉淀脚本、执行口径和后续优化方向。项目边界：所有证据与代码均限定在本项目仓库内，不引用外部项目作为验收依据。

## 执行口径总则

- 默认数据集：`HI-Small`
- 当前主机不处理 Large 数据；Large 原始文件已从 `datas` 移除，后续电脑配置升级后再考虑恢复。
- Medium 数据保留为后续扩容验证，不进入当前 P3-P4 默认流程。
- 本地阶段不连接虚拟机集群，不提交 Spark/Flink/Trino/Doris/Kafka 任务。
- 所有证据写入 `data/finance_bigdata/runs`。
- 所有问题记录到 `Optimize/问题排查总结_zh.md`。

## P0 项目地基与数据预检

- 阶段目标：确认原始文件存在、字段可读、体量可记录，建立项目独立输出证据。
- 已沉淀脚本：`src/00_finance_preflight.py`
- 执行入口：`bin/p0_p2_local_smoke.ps1`
- 执行口径：只读 `datas/HI-Small_*`，不连接集群。
- 已有证据：`data/finance_bigdata/runs/p0_preflight_20260609_200713`

## P1 数据画像

- 阶段目标：统计交易表、账户表和 Patterns 文件的基础分布。
- 已沉淀脚本：`src/01_finance_profile.py`
- 执行入口：`bin/p0_p2_local_smoke.ps1`
- 执行口径：全量扫描 `HI-Small_Trans.csv`，不一次性读入内存。
- 已有证据：`data/finance_bigdata/runs/p1_profile_20260609_200713`

## P2 ODS 小样本

- 阶段目标：生成标准字段 ODS 小样本，验证字段命名、类型转换和 Parquet 写出能力。
- 已沉淀脚本：`src/02_finance_ods_sample.py`
- 执行入口：`bin/p0_p2_local_smoke.ps1`
- 执行口径：默认写 100,000 行样本。
- 已有证据：`data/finance_bigdata/runs/p2_ods_sample_20260609_200745`

## P3 DWD 明细层

- 阶段目标：构建交易明细、账户维表、交易事件长表，并完成账户维表关联检查。
- 已沉淀脚本：`src/03_finance_dwd_build.py`
- 执行入口：`bin/p3_p4_local_build.ps1`
- 执行口径：默认处理 `HI-Small` 全量交易，输出 CSV；如果本机存在 `pyarrow`，同步输出 Parquet。
- 已有证据：`data/finance_bigdata/runs/p3_dwd_build_20260609_203822`
- 执行结果：PASS
- 关键产物：DWD 交易明细、账户维表、交易事件长表。
- 关键指标：交易明细 5,078,345 行，事件长表 10,156,690 行，账户维表 518,581 行，唯一账户 518,573 个，账户匹配率 100%。

## P4 DWS 风险指标层

- 阶段目标：构建分钟级交易 KPI、账户级风险特征、支付方式风险 KPI 和大额交易候选表。
- 已沉淀脚本：`src/04_finance_dws_risk_kpi.py`
- 执行入口：`bin/p3_p4_local_build.ps1`
- 执行口径：读取 P3 DWD 输出，优先复用本轮最新 `p3_dwd_build_*` run_dir。
- 已有证据：`data/finance_bigdata/runs/p4_dws_risk_kpi_20260609_204441`
- 执行结果：PASS
- 关键产物：分钟级交易 KPI、账户级风险特征、支付方式 KPI、大额交易候选表。
- 关键指标：分钟 KPI 88,316 行，账户风险特征 515,080 行，支付方式 KPI 7 行，大额交易候选 200,403 行。
- 规则口径：大额交易候选来自 99.5 分位阈值、绝对金额阈值、跨银行跨币种高金额组合规则。

## P5 Hive/Iceberg 集群发布

- 阶段目标：启动基础组件，将 P3/P4 Parquet 发布为金融项目独立 Iceberg 表，并完成查询层前置验收。
- 已沉淀脚本：`bin/p5_cluster_publish.sh`
- 辅助脚本：`bin/cluster_ssh.py`、`bin/cluster_start_hdfs_yarn.sh`、`bin/cluster_start_postgresql.sh`、`bin/cluster_start_hive.sh`、`bin/cluster_check_base_services.sh`、`bin/cluster_spark_smoke.sh`、`bin/cluster_p5_postcheck.sh`
- 配置文件：`config/finance_bigdata.cluster.yaml`
- 执行口径：只启动 HDFS/YARN、PostgreSQL、Hive Metastore、HiveServer2；不启动 Kafka/Flink/Doris/Trino/DolphinScheduler。
- 已有证据：`data/finance_bigdata/runs/p5_hive_iceberg_publish_20260609_064034`
- Linux 证据：`/home/common/tmp/finance_bigdata_project/runs/p5_hive_iceberg_publish_20260609_064034`
- HDFS 证据：`/lakehouse/projects/finance_bigdata/runs/p5_hive_iceberg_publish_20260609_064034`
- 执行结果：PASS
- 关键产物：`lakehouse.finance_bigdata` namespace 下 7 张 Iceberg 表。
- 校验口径：逐表 `COUNT(*)` 与 P3/P4 本地 summary 对齐。
- 后验收：Spark 能列出 7 张表，beeline 能看到 `finance_bigdata` database，P5 完成后 YARN 无 RUNNING application。

P5 每一步执行口径：

| 步骤 | 目标 | 脚本/命令 | 证据 |
| --- | --- | --- | --- |
| 基础组件启动 | 拉起 HDFS/YARN、PostgreSQL、Hive | `bin/cluster_start_*.sh` | `jps`、端口、beeline、YARN 节点检查 |
| Spark smoke | 确认 Spark on YARN 可用 | `bin/cluster_spark_smoke.sh` | `SHOW DATABASES; SELECT 1` 通过 |
| 远程目录准备 | 建立独立 Linux/HDFS 命名空间 | `mkdir`、`hdfs dfs -mkdir -p` | `/home/common/tmp/finance_bigdata_project`、`/lakehouse/projects/finance_bigdata` |
| 文件同步 | 上传 P3/P4 Parquet | `bin/cluster_ssh.py upload` | 远程 stage 总量 446MB |
| HDFS stage | 将 Parquet 放入 HDFS | `hdfs dfs -put -f` | `hdfs_stage_inventory.txt` |
| Iceberg 发布 | 创建 namespace 和 7 张表 | `spark-sql -f p5_publish.sql` | `spark_sql_publish.out` |
| 行数校验 | 与 P3/P4 summary 对齐 | `count_validation.tsv` | 7/7 PASS |
| 后验收 | 表可列出，YARN 无遗留任务 | `bin/cluster_p5_postcheck.sh` | 7 张表可见，RUNNING application=0 |

## P6 Kafka/Flink/Redis 实时风控小闭环

- 阶段目标：将 10,000 条金融交易样本写入 Kafka，由 Flink SQL 风险规则生成风险事件，再写入 Redis 最新状态。
- 已沉淀脚本：`streaming/finance_make_replay_sample.py`、`streaming/finance_collect_risk_to_redis.py`、`streaming/finance_risk_rules_flink.sql`、`bin/p6_cluster_realtime_demo.sh`
- 辅助脚本：`bin/cluster_start_realtime_services.sh`、`bin/cluster_check_realtime_services.sh`、`bin/cluster_realtime_dependency_check.sh`、`bin/cluster_p6_postcheck.sh`
- 执行口径：只启动 Kafka、Redis、Flink；不启动 Doris/Trino/DolphinScheduler；Flink 风险作业在本轮结束后取消。
- 已有证据：`data/finance_bigdata/runs/p6_realtime_demo_20260609_070436`
- Linux 证据：`/home/common/tmp/finance_bigdata_project/runs/p6_realtime_demo_20260609_070436`
- 执行结果：PASS
- 输入 topic：`finance.transactions.hi_small.20260609_070436`
- 风险 topic：`finance.risk.events.20260609_070436`
- 关键指标：Kafka 回放 10,000 条，Flink 生成并消费风险事件 559 条，Redis 写入最新状态 key 489 个。
- 风险类型分布：`LARGE_AMOUNT=377`、`LARGE_CROSS_BANK=177`、`CROSS_CURRENCY=4`、`LABEL_HIT=1`。
- 后验收：Flink 无运行作业，Redis 可查到本轮风险 key，YARN 无 RUNNING application。

P6 每一步执行口径：

| 步骤 | 目标 | 脚本/命令 | 证据 |
| --- | --- | --- | --- |
| 实时依赖检查 | 确认 Flink Kafka/JSON connector、Kafka CLI、Python 能力 | `bin/cluster_realtime_dependency_check.sh` | connector 与版本输出 |
| 回放样本生成 | 从 DWD 交易明细生成 10,000 条 JSONL | `streaming/finance_make_replay_sample.py` | `data/finance_bigdata/realtime_samples/finance_transactions_replay_10000_summary.tsv` |
| 实时组件启动 | 启动 Kafka 三节点、Redis、Flink | `bin/cluster_start_realtime_services.sh` | Kafka/Flink jps 与端口 |
| 实时组件检查 | 检查 Kafka quorum、Redis PONG、Flink job list | `bin/cluster_check_realtime_services.sh` | quorum、PONG、No running jobs |
| topic 创建 | 创建本轮 finance topic | `bin/p6_cluster_realtime_demo.sh` | `input_topic_describe.txt`、`risk_topic_describe.txt` |
| Kafka 回放 | 写入 10,000 条交易 JSON | `kafka-console-producer.sh` | `replay_count.txt` |
| Flink 风险规则 | 从 Kafka source 读交易并写风险 topic | `sql-client.sh embedded -f flink_risk_rules.sql` | `flink_sql_submit.out` |
| Redis 最新状态 | 从风险 topic 消费并写 Redis key | `streaming/finance_collect_risk_to_redis.py` | `redis_set_summary.tsv` |
| 后验收 | 取消 Flink 作业，检查 Redis/YARN | `bin/cluster_p6_postcheck.sh` | `flink_jobs_after_cancel.txt`、风险样例 |

## P7 Readiness Snapshot

- 阶段目标：固化当前平台与金融项目运行状态，确认 P0-P6 证据链和集群状态可复核。
- 已沉淀脚本：`bin/p7_cluster_readiness_snapshot.sh`、`bin/p7_local_readiness_snapshot.ps1`
- 执行口径：只做只读快照和 Spark SQL 行数校验，不新增业务数据，不等同于 P14 总验收。
- 已有证据：`data/finance_bigdata/runs/p7_readiness_snapshot_20260609_072047`
- Linux 证据：`/home/common/tmp/finance_bigdata_project/runs/p7_readiness_snapshot_20260609_072047`
- 执行结果：PASS
- 关键产物：`component_status.tsv`、`namespace_snapshot.tsv`、`table_counts.tsv`、`realtime_snapshot.tsv`、`local_evidence_snapshot.tsv`。
- 关键指标：HDFS/YARN/Hive/Kafka/Redis/Flink 检查通过；YARN running applications=0；Flink running jobs=0；7 张 Iceberg 表行数一致；Redis 风险 key=489；P0-P6 本地证据完整。

P7 每一步执行口径：

| 步骤 | 目标 | 脚本/命令 | 证据 |
| --- | --- | --- | --- |
| 节点快照 | 记录三节点内存、磁盘、JPS | `bin/p7_cluster_readiness_snapshot.sh` | `node_snapshot.txt` |
| 组件快照 | 检查 HDFS/YARN/Hive/Kafka/Redis/Flink | `bin/p7_cluster_readiness_snapshot.sh` | `component_status.tsv` |
| 命名空间快照 | 检查 Linux/HDFS/Iceberg/Kafka/Redis 命名空间 | `bin/p7_cluster_readiness_snapshot.sh` | `namespace_snapshot.tsv` |
| 表级快照 | 校验 7 张 Iceberg 表行数 | Spark SQL `COUNT(*)` | `table_counts.tsv` |
| 实时快照 | 校验 P6 topic、风险样例、Redis key | Kafka consumer、Redis scan | `realtime_snapshot.tsv` |
| 本地证据快照 | 校验 P0-P6 本地 run_dir | `bin/p7_local_readiness_snapshot.ps1` | `local_evidence_snapshot.tsv` |

## P8 交付包与演示包

- 阶段目标：冻结 P0-P7 已通过成果，生成作品集交付包和演示材料。
- 已沉淀脚本：`bin/p8_build_delivery_package.ps1`
- 执行口径：只复制 summary、TSV 和小样例文件；不复制 raw CSV、大 CSV、Parquet 明细；不新增业务数据；不等同 P14。
- 有效交付包：`data/finance_bigdata/delivery_packages/p8_delivery_package_20260609_223950`
- 执行结果：PASS
- 关键产物：`delivery_index.md`、`phase_summary.md`、`evidence_manifest.tsv`、`architecture_overview.md`、`data_lineage.md`、`demo_script.md`、`known_limits_and_next_steps.md`、`copied_summaries/`。
- 包体校验：38 个文件，manifest 30 行，无超过 5MB 的文件。
- 不完整包说明：`p8_delivery_package_20260609_223741` 是脚本缺陷产生的首次包，不作为交付结果。

P8 每一步执行口径：

| 步骤 | 目标 | 脚本/命令 | 证据 |
| --- | --- | --- | --- |
| 校验证据 | 确认 P0-P7 必需 summary 文件存在 | `bin/p8_build_delivery_package.ps1` | `steps.tsv` |
| 复制摘要 | 复制 summary/TSV/小样例 | `Copy-Evidence` | `copied_summaries/` |
| 生成文档 | 生成交付入口、阶段摘要、架构、血缘、演示脚本 | `bin/p8_build_delivery_package.ps1` | 交付包 Markdown |
| 包体校验 | 确认必需文件存在且无大文件 | `bin/p8_build_delivery_package.ps1` | `steps.tsv` |

## P9 EDA、特征工程与基线模型

- 阶段目标：在 P3/P4 已沉淀数据层上完成标签分析、建模特征样本和可解释的反洗钱分类基线。
- 已沉淀脚本：`analysis/p9_label_eda.py`、`analysis/p9_feature_build.py`、`analysis/p9_baseline_model.py`
- 执行入口：`bin/p9_local_model_baseline.ps1`
- 执行口径：读取 P3 全量交易和 P4 账户特征；使用全部正样本和 200,000 条可复现负样本；排除标签衍生账户特征；使用分层随机 75/25 切分。
- 有效证据：`data/finance_bigdata/runs/p9_model_baseline_20260609_231710`
- 执行结果：PASS
- 关键产物：`eda_summary.md`、`feature_dataset.parquet`、`feature_schema.md`、`baseline_metrics.tsv`、`feature_importance.tsv`、`model_card.md`、`p9_summary.md`。
- 关键指标：特征表 205,177 行，正样本 5,177 行；测试集 51,295 行，正样本 1,294 行；最佳模型 `random_forest_balanced`；PR-AUC 0.741912，Recall 0.909583，Precision 0.210894。
- 边界说明：P9 是作品集基线模型，不是生产级风控模型；不替代 P8 交付包，不等价于 P14 总验收。

P9 每一步执行口径：

| 步骤 | 目标 | 脚本/命令 | 证据 |
| --- | --- | --- | --- |
| 标签 EDA | 统计标签比例、金额分箱、支付方式和币种风险分布 | `analysis/p9_label_eda.py` | `label_distribution.tsv`、`eda_metrics.tsv`、`eda_summary.md` |
| 特征构建 | 抽样负样本、关联账户特征、生成训练/测试 split | `analysis/p9_feature_build.py` | `feature_dataset.parquet`、`feature_schema.md`、`train_test_split_summary.tsv` |
| 基线训练 | 训练 Logistic Regression 和 Random Forest | `analysis/p9_baseline_model.py` | `baseline_metrics.tsv`、`confusion_matrix.tsv`、`model_card.md` |
| 结果核验 | 检查指标、切分分布、特征重要性和泄漏字段 | 手工核验输出文件 | `p9_summary.md`、`feature_importance.tsv` |

P9 无效 run 说明：

- `p9_model_baseline_20260609_231338`：金额分箱 Categorical 填充值导致 EDA 失败。
- `p9_model_baseline_20260609_231421`：joblib 多进程在 Windows 环境下创建管道被拒绝，模型阶段失败。
- `p9_model_baseline_20260609_231507`：模型跑通但包含标签衍生账户特征且测试集切分失衡，不作为有效建模证据。

## P10 数仓派生特征一致性校验

- 阶段目标：验证 Iceberg 数仓层可以基于 P5 发布表复现 P9 非泄漏建模特征口径。
- 已沉淀脚本：`bin/p10_cluster_feature_parity.sh`、`bin/p10_local_feature_parity.ps1`
- 执行入口：`bin/p10_local_feature_parity.ps1`
- 执行口径：上传 P9 有效特征样本到集群；Spark 从 `lakehouse.finance_bigdata.dwd_finance_transactions` 和 `lakehouse.finance_bigdata.dws_account_risk_features` 重新派生特征；对比字段、行数、数值特征、分类特征和泄漏字段。
- 有效证据：`data/finance_bigdata/runs/p10_feature_parity_20260609_084412`
- Linux 证据：`/home/common/tmp/finance_bigdata_project/runs/p10_feature_parity_20260609_084412`
- HDFS stage：`/lakehouse/projects/finance_bigdata/stage/p10_input/p10_feature_parity_20260609_084412`
- 执行结果：PASS
- 关键产物：`source_table_counts.tsv`、`row_parity.tsv`、`required_field_scan.tsv`、`leakage_field_scan.tsv`、`numeric_parity.tsv`、`categorical_parity.tsv`、`sample_label_split_summary.tsv`、`p10_summary.md`。
- 关键指标：P9 特征样本 205,177 行全部匹配 Iceberg DWD；未匹配行数 0；数值特征 19/19 PASS；分类特征 4/4 PASS；泄漏字段扫描 4/4 PASS；YARN 后验收 PASS。
- 边界说明：P10 只做数仓特征一致性校验，不训练新模型，不修改 P9 输出，不等价于 P14 总验收。

P10 每一步执行口径：

| 步骤 | 目标 | 脚本/命令 | 证据 |
| --- | --- | --- | --- |
| 上传特征样本 | 将 P9 `feature_dataset.parquet` 放入远程 stage | `bin/p10_local_feature_parity.ps1` | `/home/common/tmp/finance_bigdata_project/stage/p10_input/feature_dataset.parquet` |
| HDFS stage | 将 P9 特征样本写入 HDFS | `bin/p10_cluster_feature_parity.sh` | `hdfs_stage_inventory.txt` |
| 字段扫描 | 检查必需字段存在，泄漏字段不存在 | Spark `DESCRIBE` + Bash scan | `required_field_scan.tsv`、`leakage_field_scan.tsv` |
| 源表校验 | 校验 Iceberg 源表行数 | Spark SQL `COUNT(*)` | `source_table_counts.tsv` |
| 行级匹配 | 确认 P9 transaction_id 全部能从 DWD 匹配 | Spark SQL join | `row_parity.tsv` |
| 数值一致性 | 校验金额、时间、账户特征、比例特征和标签 | Spark SQL 差异统计 | `numeric_parity.tsv` |
| 分类一致性 | 校验日期、split、币种、支付方式 | Spark SQL 差异统计 | `categorical_parity.tsv` |
| 后验收 | 确认 YARN 无运行任务残留 | `yarn application -list` | `postcheck.tsv` |

P10 无效 run 说明：

- `p10_feature_parity_20260609_084100`：首次 P10 运行状态通过，但 Spark stdout 日志混入 TSV 证据文件；脚本已增加 stdout 过滤后重跑，不作为有效 P10 证据。

## P11 实时风控评分契约

- 阶段目标：在 P9/P10 非泄漏特征口径基础上，沉淀实时输入/输出 schema，并完成独立 Kafka/Flink/Redis 评分契约小闭环。
- 已沉淀脚本：`streaming/finance_make_scoring_contract_sample.py`、`streaming/finance_scoring_contract_flink.sql`、`streaming/finance_collect_contract_to_redis.py`、`bin/p11_cluster_realtime_scoring_contract.sh`、`bin/p11_local_realtime_scoring_contract.ps1`
- 契约文档：`contracts/p11_realtime_scoring_contract_zh.md`
- 执行入口：`bin/p11_local_realtime_scoring_contract.ps1`
- 执行口径：读取 P9 特征表和 P3 交易明细生成 10,000 条实时评分样本；评分规则只使用非泄漏字段；输出风险事件必须通过 schema 校验；结果写入独立 P11 topic 和 Redis key 前缀。
- 有效证据：`data/finance_bigdata/runs/p11_realtime_scoring_contract_20260611_011424`
- Linux 证据：`/home/common/tmp/finance_bigdata_project/runs/p11_realtime_scoring_contract_20260611_011424`
- 执行结果：PASS
- 输入 topic：`finance-p11-scoring-input-20260611011424`
- 风险 topic：`finance-p11-risk-events-20260611011424`
- Redis key 前缀：`finance_bigdata:p11:risk:latest:*`
- 关键产物：`p11_summary.md`、`p11_realtime_scoring_contract_zh.md`、`local_sample_summary.tsv`、`redis_contract_summary.tsv`、`risk_events_sample.jsonl`、`postcheck.tsv`、`flink_scoring_contract.sql`。
- 关键指标：输入样本 10,000 条；风险事件 8,119 条；schema 有效 8,119 条；schema 无效 0 条；Redis key 6,451 个；Flink/YARN 后验收 PASS。
- 边界说明：P11 只做实时评分契约和小闭环，不训练新模型，不替代 P9，不等价于 P14 总验收。

P11 每一步执行口径：

| 步骤 | 目标 | 脚本/命令 | 证据 |
| --- | --- | --- | --- |
| 样本生成 | 由 P9 特征表和 P3 交易明细生成评分契约 JSONL | `streaming/finance_make_scoring_contract_sample.py` | `local_sample_summary.tsv` |
| 契约上传 | 上传 Flink SQL、Redis 收集脚本和契约文档 | `bin/p11_local_realtime_scoring_contract.ps1` | 远程 `streaming/`、`contracts/` |
| 组件检查 | 检查 Kafka、Redis、Flink 无运行作业 | `bin/p11_cluster_realtime_scoring_contract.sh` | `kafka_quorum.out`、`redis_ping.out`、`flink_jobs_before.txt` |
| topic 创建 | 创建 P11 独立 input/risk topic | Kafka CLI | `input_topic_describe.txt`、`risk_topic_describe.txt` |
| Kafka 回放 | 写入 10,000 条评分契约样本 | `kafka-console-producer.sh` | `replay_count.txt`、`producer_status.txt` |
| Flink 评分 | 根据非泄漏字段生成风险评分事件 | `finance_scoring_contract_flink.sql` | `flink_sql_submit.out`、`risk_events_raw.jsonl` |
| Schema 校验与 Redis | 校验风险输出 schema 并写 Redis latest-state | `streaming/finance_collect_contract_to_redis.py` | `redis_contract_summary.tsv`、`risk_events_sample.jsonl` |
| 后验收 | 取消本轮 Flink 作业，检查 Flink/YARN 无残留 | `flink cancel`、`yarn application -list` | `postcheck.tsv` |

## P12 Trino/Doris 查询层验证

- 阶段目标：验证 P5 发布的 Iceberg 表、P11 实时结果残留和 Doris smoke 指标可以被查询层消费。
- 已沉淀脚本：`bin/p12_cluster_query_layer_validation.sh`、`bin/p12_local_query_layer_validation.ps1`
- 执行入口：`bin/p12_local_query_layer_validation.ps1`
- 执行口径：本地入口先启动 HDFS/YARN、PostgreSQL、Hive；集群侧启动/检查 Trino，自动发现 Trino CLI，通过 `iceberg.finance_bigdata` 查询 7 张 Iceberg 表；Doris 作为 best-effort 查询 smoke 单独记录状态。
- 有效证据：`data/finance_bigdata/runs/p12_query_layer_validation_20260611_013546`
- Linux 证据：`/home/common/tmp/finance_bigdata_project/runs/p12_query_layer_validation_20260611_013546`
- 执行结果：PASS
- Trino catalog/schema：`iceberg.finance_bigdata`
- 关键产物：`p12_summary.md`、`p12_status.tsv`、`trino_query_status.tsv`、`trino_table_counts.tsv`、`doris_status.tsv`、`doris_query_summary.tsv`、`realtime_residue.tsv`、`postcheck.tsv`。
- 关键指标：Trino 3 个节点可见；7 张 Iceberg 表行数全部 PASS；4 类业务查询全部 PASS；P11 Redis key 6,451 个；Doris FE/BE/query smoke PASS；YARN 后验收 PASS。
- 边界说明：P12 只做查询层验证，不重建 P9/P10/P11，不训练新模型，不等价于 P14 总验收。

P12 每一步执行口径：

| 步骤 | 目标 | 脚本/命令 | 证据 |
| --- | --- | --- | --- |
| 基础组件启动 | 拉起 HDFS/YARN、PostgreSQL、Hive | `bin/p12_local_query_layer_validation.ps1` 调用 `cluster_start_*.sh` | 组件启动终端输出 |
| 基础组件检查 | 确认 HDFS、YARN、Hive 可用 | `bin/p12_cluster_query_layer_validation.sh` | `component_status.tsv` |
| Trino 启动检查 | 启动/检查三节点 Trino 并发现 CLI | `launcher start/status`、`find_trino_cli` | `trino_launcher_status.txt`、`trino_cli_path.txt` |
| Trino 元数据查询 | 查询节点、schema、表清单和 7 张表行数 | Trino CLI | `trino_query_status.tsv`、`trino_table_counts.tsv` |
| 业务查询验证 | 验证支付方式风险、大额交易、账户风险、小时分布查询 | Trino SQL | `trino_payment_format_risk.tsv`、`trino_large_transaction_topn.tsv`、`trino_account_risk_topn.tsv`、`trino_hourly_laundering_distribution.tsv` |
| P11 残留检查 | 确认实时评分 Redis key 仍可读取 | `redis-cli --scan`、`GET` | `realtime_residue.tsv`、`p11_redis_risk_sample.json` |
| Doris smoke | 启动/检查 FE/BE 并写入查询 4 条指标 | Doris MySQL protocol | `doris_status.tsv`、`doris_query_summary.tsv` |
| 后验收与下载 | 检查 YARN 无运行任务并下载本地证据 | `yarn application -list`、`cluster_ssh.py download` | `postcheck.tsv`、本地 P12 run_dir |

## P13 BI 仪表盘材料包

- 阶段目标：把 P12 查询层输出和 P11 实时摘要沉淀为可携带、可演示、可复盘的 BI 仪表盘材料。
- 已沉淀脚本：`bin/p13_build_bi_dashboard_package.ps1`
- 执行入口：`bin/p13_build_bi_dashboard_package.ps1`
- 执行口径：只读取 P11/P12 小型证据文件，不连接虚拟机集群，不提交 Trino/Doris/Flink 作业，不复制原始 CSV、大 CSV 或 Parquet 明细。
- 有效包：`data/finance_bigdata/bi_packages/p13_bi_dashboard_package_20260611_172808`
- 执行结果：PASS
- 关键产物：`dashboard_index.md`、`dashboard_metric_catalog.md`、`dashboard_page_design.md`、`dashboard_sql_reference.md`、`dashboard_demo_script.md`、`dashboard_preview.html`、`copied_dashboard_data/`、`p13_status.tsv`、`p13_summary.md`。
- 关键指标：P12/P11 源证据 PASS；包内 22 个文件；最大文件 13,774 bytes；原始 CSV/Parquet 文件数 0；必需文件缺失数 0。
- 边界说明：P13 是 BI 展示材料包，不重建数据层，不训练模型，不等价于 P14 总验收。
- 非最终包说明：`p13_bi_dashboard_package_20260611_172652` 是脚本修正前的首次包，不作为有效 P13 结果。

P13 每一步执行口径：

| 步骤 | 目标 | 脚本/命令 | 证据 |
| --- | --- | --- | --- |
| 源证据检查 | 确认 P12/P11 必需小型证据文件存在且 P12 为 PASS | `bin/p13_build_bi_dashboard_package.ps1` | `p12_status.tsv`、`p11_summary.md` |
| 证据复制 | 复制 dashboard-ready TSV/JSON/summary 文件 | `Copy-Item` | `copied_dashboard_data/` |
| 指标口径生成 | 说明指标定义、数据来源和边界 | `bin/p13_build_bi_dashboard_package.ps1` | `dashboard_metric_catalog.md` |
| 页面设计生成 | 说明 Executive Overview、Investigation Workbench、Lineage 页面结构 | `bin/p13_build_bi_dashboard_package.ps1` | `dashboard_page_design.md` |
| SQL 参考生成 | 固化 Trino/Doris 查询语句 | `bin/p13_build_bi_dashboard_package.ps1` | `dashboard_sql_reference.md` |
| 静态预览生成 | 生成离线可打开的 HTML 仪表盘预览 | `bin/p13_build_bi_dashboard_package.ps1` | `dashboard_preview.html` |
| 包体校验 | 检查文件数、最大文件、原始 CSV/Parquet 禁止项和必需文件 | `bin/p13_build_bi_dashboard_package.ps1` | `p13_status.tsv`、`p13_summary.md` |

## P14 金融项目独立总验收

- 阶段目标：对 P0-P13 的有效证据链、关键指标、边界隔离和交付 readiness 做独立 master validation。
- 已沉淀脚本：`bin/p14_finance_master_validation.ps1`
- 执行入口：`bin/p14_finance_master_validation.ps1`
- 执行口径：只读取本地已沉淀证据，不启动虚拟机集群，不重建数据层，不处理 Medium/Large，不训练新模型。
- 有效证据：`data/finance_bigdata/runs/p14_master_validation_20260611_184955`
- 执行结果：PASS
- 关键产物：`p14_summary.md`、`summary.tsv`、`p14_steps.tsv`、`phase_evidence_status.tsv`、`key_metric_validation.tsv`、`boundary_scan.tsv`、`delivery_readiness.tsv`、`invalid_evidence_inventory.tsv`。
- 关键指标：阶段证据 14/14 PASS；关键指标 26/26 PASS；边界扫描 8/8 PASS；交付 readiness 7/7 PASS；非最终证据 10 项均已排除。
- 边界说明：P14 是金融项目独立总验收，不使用外部项目证据，不等于平台通用验收。
- 非最终 P14 说明：`p14_master_validation_20260611_184727`、`p14_master_validation_20260611_184833`、`p14_master_validation_20260611_184903` 均为脚本修正过程中的非最终目录，不作为有效 P14。

P14 每一步执行口径：

| 步骤 | 目标 | 脚本/命令 | 证据 |
| --- | --- | --- | --- |
| 阶段证据校验 | 校验 P0-P13 有效 run/package 和必需文件 | `bin/p14_finance_master_validation.ps1` | `phase_evidence_status.tsv` |
| 关键指标校验 | 校验 26 个核心指标与预期一致 | `bin/p14_finance_master_validation.ps1` | `key_metric_validation.tsv` |
| 边界扫描 | 校验 Large、原始数据、密码、外部项目边界 | `bin/p14_finance_master_validation.ps1` | `boundary_scan.tsv` |
| 交付 readiness | 校验 P8、P13 和 P14 交付入口完整 | `bin/p14_finance_master_validation.ps1` | `delivery_readiness.tsv` |
| 非最终证据排除 | 标记失败 run 和修正前包，避免误用 | `bin/p14_finance_master_validation.ps1` | `invalid_evidence_inventory.tsv` |
| 总验收结论 | 汇总所有检查项形成 P14 PASS/FAIL | `bin/p14_finance_master_validation.ps1` | `summary.tsv`、`p14_summary.md` |

## P15 重启恢复 Readiness

- 阶段目标：验证虚拟机重启后，本项目所需服务可以按顺序恢复，并且 Iceberg 表与实时组件仍可用。
- 已沉淀脚本：`bin/p15_local_restart_readiness.ps1`、`bin/p15_cluster_restart_readiness.sh`
- 执行入口：`bin/p15_local_restart_readiness.ps1`
- 执行口径：本地入口依次启动 HDFS/YARN、PostgreSQL、Hive、Kafka、Redis、Flink；集群侧只读检查组件、Iceberg 表行数、Kafka topic 和 Redis latest-state key。
- 有效证据：`data/finance_bigdata/runs/p15_restart_readiness_20260613_211415`
- Linux 证据：`/home/common/tmp/finance_bigdata_project/runs/p15_restart_readiness_20260613_061540`
- 执行结果：PASS
- 关键产物：`p15_summary.md`、`p15_local_summary.md`、`p15_status.tsv`、`component_status.tsv`、`table_counts.tsv`、`realtime_restart_status.tsv`、`local_steps.tsv`。
- 关键指标：本地启动步骤 6/6 PASS；组件 9/9 PASS；Iceberg 表 7/7 PASS；finance topic 数 4；P6 Redis key 489；P11 Redis key 6,451。
- 边界说明：P15 是重启恢复检查，不重建业务数据，不处理 Medium/Large，不替代 P14。
- 非最终说明：`p15_restart_readiness_20260613_211319` 是 runner 修正前目录，不作为有效 P15。

P15 每一步执行口径：

| 步骤 | 目标 | 脚本/命令 | 证据 |
| --- | --- | --- | --- |
| 启动 HDFS/YARN | 恢复分布式存储和资源管理 | `cluster_start_hdfs_yarn.sh` | `start_hdfs_yarn.out` |
| 启动 PostgreSQL | 恢复 Hive Metastore 依赖 | `cluster_start_postgresql.sh` | `start_postgresql.out` |
| 启动 Hive | 恢复 Metastore 和 HiveServer2 | `cluster_start_hive.sh` | `start_hive.out` |
| 启动实时服务 | 恢复 Kafka、Redis、Flink | `cluster_start_realtime_services.sh` | `start_realtime_services.out` |
| 集群检查 | 检查组件、表、实时状态 | `p15_cluster_restart_readiness.sh` | `component_status.tsv`、`table_counts.tsv`、`realtime_restart_status.tsv` |
| 证据下载 | 下载 P15 远程证据到本地 | `cluster_ssh.py download` | `download_evidence.out`、本地 P15 run_dir |

## P16 AI 解释增强

- 阶段目标：把 P9 模型结果转化为更适合模型解释和展示说明材料，并补充无监督异常检测实验。
- 已沉淀脚本：`analysis/p16_model_explainability.py`、`bin/p16_local_ai_learning.ps1`
- 执行入口：`bin/p16_local_ai_learning.ps1`
- 执行口径：只读取 P9 有效特征表和模型结果；Isolation Forest 使用 50,000 行抽样样本；不连接集群，不重训 P9 替代模型。
- 有效证据：`data/finance_bigdata/runs/p16_model_explainability_20260613_211955`
- 执行结果：PASS
- 关键产物：`p16_summary.md`、`p16_status.tsv`、`model_explainability_report.md`、`feature_importance_top20.tsv`、`feature_group_summary.tsv`、`confusion_matrix_interpretation.tsv`、`anomaly_detection_report.md`、`anomaly_detection_summary.tsv`、`anomaly_score_deciles.tsv`、`top_anomaly_transactions.tsv`。
- 展示材料：项目讲解稿、项目答辩问答等轻量文档
- 关键指标：P9 特征行数 205,177；最佳模型 `random_forest_balanced`；PR-AUC 0.741912；Isolation Forest 样本 50,000 行；异常 1,500 行；异常正样本 198；异常组 lift 1.27487。
- 边界说明：P16 是 AI 解释增强，不替代 P9/P14，不声明生产级 AML 效果。

P16 每一步执行口径：

| 步骤 | 目标 | 脚本/命令 | 证据 |
| --- | --- | --- | --- |
| 源数据读取 | 读取 P9 特征表、指标和特征重要性 | `analysis/p16_model_explainability.py` | `p16_status.tsv` |
| 模型解释 | 汇总 Top20 特征和特征组贡献 | `analysis/p16_model_explainability.py` | `feature_importance_top20.tsv`、`feature_group_summary.tsv` |
| 指标解释 | 解释混淆矩阵、Precision、Recall、PR-AUC | `analysis/p16_model_explainability.py` | `confusion_matrix_interpretation.tsv` |
| 异常检测 | 使用 Isolation Forest 做无监督异常检测实验 | `analysis/p16_model_explainability.py` | `anomaly_detection_summary.tsv`、`top_anomaly_transactions.tsv` |
| 报告生成 | 生成模型解释和异常检测报告 | `analysis/p16_model_explainability.py` | `model_explainability_report.md`、`anomaly_detection_report.md` |
| 展示材料 | 生成讲解稿和项目答辩问答 | 手工文档沉淀 | 项目展示说明材料 |

## P17 数据质量与监控规则

- 阶段目标：把 P0-P16 已验收证据转化为可复用的数据质量检查规则，并形成后续监控的规则雏形。
- 已沉淀脚本：`bin/p17_data_quality_check.ps1`
- 已沉淀规则文档：`quality/finance_quality_rules.md`
- 执行入口：`bin/p17_data_quality_check.ps1`
- 执行口径：只读取本地有效证据，不启动虚拟机集群，不重建数据层，不训练模型，不处理 Medium/Large。
- 有效证据：`data/finance_bigdata/runs/p17_data_quality_check_20260613_212741`
- 执行结果：PASS
- 关键产物：`p17_summary.md`、`p17_status.tsv`、`quality_check_results.tsv`、`quality/finance_quality_rules.md`。
- 关键指标：检查项 20；PASS 20；WARN 0；FAIL 0。
- 边界说明：P17 是质量规则和监控口径沉淀，不是新的 ETL 层，也不替代 P14 总验收。

P17 每一步执行口径：

| 步骤 | 目标 | 脚本/命令 | 证据 |
| --- | --- | --- | --- |
| 源证据定位 | 定位 P0-P16 有效 run/package | `bin/p17_data_quality_check.ps1` | `p17_status.tsv` |
| 质量规则检查 | 检查行数、标签、特征、实时契约、查询、包边界和重启恢复 | `bin/p17_data_quality_check.ps1` | `quality_check_results.tsv` |
| 规则文档生成 | 固化当前阈值和监控说明 | `bin/p17_data_quality_check.ps1` | `quality/finance_quality_rules.md` |
| 状态汇总 | 汇总 PASS/WARN/FAIL 并输出 P17 状态 | `bin/p17_data_quality_check.ps1` | `p17_summary.md`、`p17_status.tsv` |

## P18 作品集最终交付包增强

- 阶段目标：生成面向作品集展示的最终轻量导航包，把 P13 BI、P14 总验收、P15 重启恢复、P16 AI 解释增强和 P17 数据质量规则串成可演示入口。
- 已沉淀脚本：`bin/p18_build_portfolio_final_package.ps1`
- 已沉淀入口：`portfolio/金融大数据项目作品集入口.md`
- 执行入口：`bin/p18_build_portfolio_final_package.ps1`
- 执行口径：只复制小型 Markdown、TSV、JSON 样例和 HTML 预览，不复制 `datas/` 原始数据、大 CSV、Parquet 明细、凭据或外部项目证据。
- 有效包：`data/finance_bigdata/portfolio_packages/p18_portfolio_final_package_20260613_213025`
- 执行结果：PASS
- 关键产物：`portfolio_index.md`、`portfolio_story.md`、`final_demo_checklist.md`、`copied_materials/`、`p18_summary.md`、`p18_status.tsv`。
- 关键指标：P14/P15/P16/P17 状态均 PASS；包内文件数 21；原始 CSV 或 Parquet 文件数 0；必需文件缺失数 0。
- 边界说明：P18 是作品集最终交付包，不新增业务数据处理，不替代 P14/P17。
- 非最终说明：`p18_portfolio_final_package_20260613_212751` 是脚本口径修正前首次包，因演示清单路径和文件计数报告口径不严，不作为最终 P18 包。

P18 每一步执行口径：

| 步骤 | 目标 | 脚本/命令 | 证据 |
| --- | --- | --- | --- |
| 源状态读取 | 读取 P14/P15/P16/P17 有效状态 | `bin/p18_build_portfolio_final_package.ps1` | `p18_status.tsv` |
| 入口生成 | 生成项目根作品集入口和包内导航页 | `bin/p18_build_portfolio_final_package.ps1` | `portfolio/金融大数据项目作品集入口.md`、`portfolio_index.md` |
| 轻量材料复制 | 复制讲解稿、问答、P13/P16/P17 小型材料 | `Copy-Item` | `copied_materials/` |
| 演示清单生成 | 固化最终展示顺序和文件路径 | `bin/p18_build_portfolio_final_package.ps1` | `final_demo_checklist.md` |
| 包边界校验 | 检查原始 CSV、Parquet、大文件和必需文件 | `bin/p18_build_portfolio_final_package.ps1` | `p18_status.tsv`、`p18_summary.md` |

