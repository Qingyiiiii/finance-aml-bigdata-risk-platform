# bin 说明

Language: [中文](README_zh.md) | [English](README_en.md)

`bin/` 是项目的阶段执行入口和集群辅助脚本目录。PowerShell 脚本用于 Windows 本地编排，`.sh` 脚本用于 Linux 集群侧执行，`cluster_ssh.py` 负责 asyncssh 远程执行和文件传输。

## 本地阶段入口

| 脚本 | 阶段 | 作用 | 是否启动集群 |
| --- | --- | --- | --- |
| `p0_p2_local_smoke.ps1` | P0-P2 | 本地预检、profile、ODS 样本 | 否 |
| `p3_p4_local_build.ps1` | P3-P4 | 本地 DWD/DWS 构建 | 否 |
| `p7_local_readiness_snapshot.ps1` | P7 | 远程 readiness 执行与证据下载 | 是，读取集群 |
| `p8_build_delivery_package.ps1` | P8 | 交付包冻结 | 否 |
| `p9_local_model_baseline.ps1` | P9 | EDA、特征、基线模型顺序执行 | 否 |
| `p10_local_feature_parity.ps1` | P10 | 上传脚本、远程执行、下载证据 | 是 |
| `p11_local_realtime_scoring_contract.ps1` | P11 | 生成样本、上传、远程实时契约验证 | 是 |
| `p12_local_query_layer_validation.ps1` | P12 | 查询层验证编排与证据下载 | 是 |
| `p13_build_bi_dashboard_package.ps1` | P13 | BI 材料包生成 | 否 |
| `p14_finance_master_validation.ps1` | P14 | 金融项目总验收 | 否，读取既有证据 |
| `p15_local_restart_readiness.ps1` | P15 | 重启恢复验证编排 | 是 |
| `p16_local_ai_learning.ps1` | P16 | 模型解释与异常检测学习 | 否 |
| `p17_data_quality_check.ps1` | P17 | 数据质量规则检查 | 否，读取既有证据 |
| `p18_build_portfolio_final_package.ps1` | P18 | 最终作品集包生成 | 否 |

## 集群侧脚本

| 脚本 | 作用 |
| --- | --- |
| `cluster_start_hdfs_yarn.sh` | 启动 HDFS/YARN 基础服务 |
| `cluster_start_postgresql.sh` | 启动 PostgreSQL |
| `cluster_start_hive.sh` | 启动 Hive Metastore/HiveServer2 |
| `cluster_start_realtime_services.sh` | 启动 Kafka/Redis/Flink |
| `cluster_check_base_services.sh` | 检查基础服务 |
| `cluster_check_realtime_services.sh` | 检查实时服务 |
| `cluster_spark_smoke.sh` | Spark SQL smoke |
| `cluster_realtime_dependency_check.sh` | Flink/Kafka/Redis/Python 依赖检查 |
| `p5_cluster_publish.sh` | 发布 Iceberg 表 |
| `p6_cluster_realtime_demo.sh` | P6 实时风控 demo |
| `p7_cluster_readiness_snapshot.sh` | P7 readiness 快照 |
| `p10_cluster_feature_parity.sh` | P10 数仓特征一致性 |
| `p11_cluster_realtime_scoring_contract.sh` | P11 实时评分契约 |
| `p12_cluster_query_layer_validation.sh` | P12 Trino/Doris 查询验证 |
| `p15_cluster_restart_readiness.sh` | P15 集群重启恢复检查 |

## 展示边界

- 本目录只保留运行入口、阶段职责和边界说明，不保留逐步讲解式注释。
- 远程执行、服务启动、安装和修复类脚本需要在确认当前环境状态后再运行。
- 脚本中的密码、token、secret 字样仅作为变量名、环境变量名或脱敏扫描规则使用，不应包含明文凭据。
- 阶段脚本执行成功不等同于全链路验收；总体验收以 P14/P17/P18 类汇总证据为准。

