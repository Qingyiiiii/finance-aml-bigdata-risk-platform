# bin

Language: [中文](README_zh.md) | [English](README_en.md)

`bin/` contains stage entry points and cluster helper scripts. PowerShell scripts orchestrate local Windows-side workflows, `.sh` scripts run on the Linux cluster side, and `cluster_ssh.py` handles asyncssh-based remote execution and file transfer.

### Local Stage Entry Points

| Script | Phase | Purpose | Starts Cluster Services |
| --- | --- | --- | --- |
| `p0_p2_local_smoke.ps1` | P0-P2 | Local preflight, profiling and ODS sample build | No |
| `p3_p4_local_build.ps1` | P3-P4 | Local DWD/DWS build | No |
| `p7_local_readiness_snapshot.ps1` | P7 | Remote readiness execution and evidence download | Yes, reads cluster state |
| `p8_build_delivery_package.ps1` | P8 | Freeze the delivery package | No |
| `p9_local_model_baseline.ps1` | P9 | Run EDA, feature engineering and baseline modeling in order | No |
| `p10_local_feature_parity.ps1` | P10 | Upload scripts, run remote validation and download evidence | Yes |
| `p11_local_realtime_scoring_contract.ps1` | P11 | Generate samples, upload assets and validate the realtime scoring contract | Yes |
| `p12_local_query_layer_validation.ps1` | P12 | Orchestrate query-layer validation and evidence download | Yes |
| `p13_build_bi_dashboard_package.ps1` | P13 | Build BI dashboard materials | No |
| `p14_finance_master_validation.ps1` | P14 | Run finance project master validation | No, reads existing evidence |
| `p15_local_restart_readiness.ps1` | P15 | Orchestrate restart readiness validation | Yes |
| `p16_local_ai_learning.ps1` | P16 | Run model explainability and anomaly detection learning tasks | No |
| `p17_data_quality_check.ps1` | P17 | Run data quality rule checks | No, reads existing evidence |
| `p18_build_portfolio_final_package.ps1` | P18 | Build the final portfolio package | No |

### Cluster-side Scripts

| Script | Purpose |
| --- | --- |
| `cluster_start_hdfs_yarn.sh` | Start HDFS/YARN base services |
| `cluster_start_postgresql.sh` | Start PostgreSQL |
| `cluster_start_hive.sh` | Start Hive Metastore/HiveServer2 |
| `cluster_start_realtime_services.sh` | Start Kafka/Redis/Flink |
| `cluster_check_base_services.sh` | Check base services |
| `cluster_check_realtime_services.sh` | Check realtime services |
| `cluster_spark_smoke.sh` | Run Spark SQL smoke validation |
| `cluster_realtime_dependency_check.sh` | Check Flink/Kafka/Redis/Python dependencies |
| `p5_cluster_publish.sh` | Publish Iceberg tables |
| `p6_cluster_realtime_demo.sh` | Run P6 realtime risk demo |
| `p7_cluster_readiness_snapshot.sh` | Generate P7 readiness snapshot |
| `p10_cluster_feature_parity.sh` | Validate P10 warehouse feature parity |
| `p11_cluster_realtime_scoring_contract.sh` | Validate P11 realtime scoring contract |
| `p12_cluster_query_layer_validation.sh` | Validate P12 Trino/Doris query layer |
| `p15_cluster_restart_readiness.sh` | Check P15 cluster restart readiness |

### Public Boundary

- This directory keeps runnable entry points, stage responsibilities and boundary notes only. It does not retain tutorial-style line-by-line explanations.
- Remote execution, service startup, installation and repair scripts should be run only after the current environment state is confirmed.
- Words such as password, token and secret may appear only as variable names, environment variable names or masking-scan patterns. They must not contain plaintext credentials.
- A successful stage script does not equal full-chain validation. Overall validation is based on aggregated evidence from P14/P17/P18-style checks.

