# 金融大数据项目问题排查总结

Language: [中文](问题排查总结_zh.md) | [English](Summary-of-Problem-Investigation_en.md)

本文档用于沉淀金融大数据项目执行过程中的报错、判断、修正和后续优化。平台底座问题仍优先记录到平台文档；本文件只记录本项目级问题。

## 记录模板

### 现象

- 时间：
- 项目：
- 任务/脚本：
- 报错摘要：
- 关键日志路径：

### 判断

- 根因分类：
- 影响组件：
- 是否影响平台底座：

### 修正

- 执行命令或代码变更：
- 配置变更：
- 数据修复：

### 后续优化

- 需要补充的自动化检查：
- 需要沉淀到项目文档的步骤：
- 需要新增的监控或告警：

### 影响范围

- 影响的数据层：
- 影响的任务：
- 是否需要重跑：

## 已记录问题

### 2026-07-03 P18v2 边界说明自触发外部项目关键词扫描

### 现象

- 时间：2026-07-03
- 项目：finance_bigdata_v2
- 任务/脚本：`bin\p18v2_build_portfolio_final_package.ps1`
- 报错摘要：P18v2 包边界扫描 `external_project_keyword_hit_count` 为 2，且命中来自包内边界说明和复制的 P14v2 边界表
- 关键日志路径：`data\finance_bigdata_v2\portfolio_packages\p18v2_portfolio_final_package_20260703_142819\package_boundary_scan.tsv`

### 判断

- 根因分类：边界检查说明文字自触发关键词扫描
- 影响组件：P14v2 边界表输出、P18v2 最终包说明与扫描项名称
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：保留实际外部项目关键词扫描规则，但将对外交付的边界行名和说明改为中性描述
- 配置变更：无
- 数据修复：无

### 后续优化

- 需要补充的自动化检查：最终包扫描应覆盖生成后的全包文本，避免验收说明自带禁止词
- 需要沉淀到项目文档的步骤：作品集包内只保留 本项目边界结论，不写入外部项目名称
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无
- 影响的任务：P18v2 第二次执行状态为 FAIL，修正后需重新跑 P14v2 和 P18v2
- 是否需要重跑：需要重跑 P14v2/P18v2 本地验收脚本

### 2026-07-03 P18v2 GetRelativePath 运行时兼容性

### 现象

- 时间：2026-07-03
- 项目：finance_bigdata_v2
- 任务/脚本：`bin\p18v2_build_portfolio_final_package.ps1`
- 报错摘要：当前运行时返回 `[System.IO.Path] does not contain a method named 'GetRelativePath'`
- 关键日志路径：首次 P18v2 终端返回；脚本停在复制材料清单生成阶段

### 判断

- 根因分类：.NET/PowerShell API 版本兼容性
- 影响组件：P18v2 本地最终包生成脚本的相对路径记录
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：新增 `Get-RelativePathCompat`，使用 `System.Uri.MakeRelativeUri` 计算相对路径
- 配置变更：无
- 数据修复：无

### 后续优化

- 需要补充的自动化检查：避免在项目脚本中直接依赖较新 .NET API，优先使用兼容实现
- 需要沉淀到项目文档的步骤：P18v2 包内材料清单继续记录相对路径，不要求升级 PowerShell
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无
- 影响的任务：P18v2 首次执行中断，修正后重跑即可
- 是否需要重跑：需要重跑 P18v2 本地最终包生成脚本

### 2026-07-03 P14v2 Select-String 递归参数兼容性

### 现象

- 时间：2026-07-03
- 项目：finance_bigdata_v2
- 任务/脚本：`bin\p14v2_master_validation.ps1`
- 报错摘要：本机 PowerShell 返回 `A parameter cannot be found that matches parameter name 'Recurse'`
- 关键日志路径：首次 P14v2 终端返回；脚本停在敏感信息递归扫描阶段

### 判断

- 根因分类：PowerShell cmdlet 参数兼容性
- 影响组件：P14v2 本地验收脚本的边界扫描
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：将 `Select-String -Recurse` 改为 `Get-ChildItem -Recurse -File | Select-String`
- 配置变更：无
- 数据修复：无

### 后续优化

- 需要补充的自动化检查：PowerShell 脚本除解析检查外，保留一次本机 dry-run/兼容性运行
- 需要沉淀到项目文档的步骤：P14v2/P18v2 本地扫描统一使用 `Get-ChildItem` 枚举文件
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无
- 影响的任务：P14v2 首次执行中断，修正后重跑即可
- 是否需要重跑：需要重跑 P14v2 本地验收脚本

### 2026-06-09 P0 语法检查写入 pycache 被拒绝

### 现象

- 时间：2026-06-09
- 项目：finance_bigdata
- 任务/脚本：`python -m py_compile src\finance_utils.py src\00_finance_preflight.py src\01_finance_profile.py src\02_finance_ods_sample.py`
- 报错摘要：Windows 拒绝将临时 `.pyc` 文件重命名为 `src\__pycache__\finance_utils.cpython-313.pyc`
- 关键日志路径：无独立日志，终端返回 `[WinError 5] 拒绝访问`

### 判断

- 根因分类：本地 Python 字节码缓存写入问题
- 影响组件：本地语法检查命令
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：改用 `python -B -c "compile(...)"` 做不落盘语法检查
- 配置变更：`bin/p0_p2_local_smoke.ps1` 增加 `$env:PYTHONDONTWRITEBYTECODE = "1"`，并使用 `python -B`
- 数据修复：无

### 后续优化

- 需要补充的自动化检查：所有本地 runner 默认禁用字节码写入
- 需要沉淀到项目文档的步骤：本地执行入口统一用 `python -B`
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无
- 影响的任务：语法检查，不影响 P0-P2 数据输出
- 是否需要重跑：不需要

### 2026-06-09 P3 账户行数与唯一账户数口径区分

### 现象

- 时间：2026-06-09
- 项目：finance_bigdata
- 任务/脚本：`src/03_finance_dwd_build.py`
- 报错摘要：不是运行失败；P3 初版 summary 中 `account_rows` 实际记录的是唯一账户数，容易和账户维表原始行数混淆。
- 关键日志路径：`data/finance_bigdata/runs/p3_dwd_build_20260609_203822/dwd_summary.tsv`

### 判断

- 根因分类：指标命名口径不清
- 影响组件：P3 DWD summary 与报告文本
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：`src/03_finance_dwd_build.py` 增加 `unique_account_count` 和 `duplicate_account_number_count`
- 配置变更：无
- 数据修复：修正本轮 `dwd_summary.tsv`、`dwd_summary.md`、`dwd_validation_summary.json` 的统计口径；未重跑大文件生成

### 后续优化

- 需要补充的自动化检查：DWD summary 中同时记录原始行数、唯一键数、重复键数
- 需要沉淀到项目文档的步骤：账户维表校验必须区分行数和唯一账户数
- 需要新增的监控或告警：维表主键重复率可作为后续数据质量指标

### 影响范围

- 影响的数据层：DWD 账户维表统计报告
- 影响的任务：P3 summary，不影响 DWD CSV/Parquet 明细数据
- 是否需要重跑：不需要

### 2026-06-09 P5 PowerShell 远程命令引号解析失败

### 现象

- 时间：2026-06-09
- 项目：finance_bigdata
- 任务/脚本：P5 基础服务启动与后验收的远程命令
- 报错摘要：PowerShell 将远程 Bash 命令中的管道符、引号和分号提前解析，导致命令没有按预期传到 hadoop1。
- 关键日志路径：终端报错，未生成远程日志。

### 判断

- 根因分类：本地命令封装问题
- 影响组件：本地到远程的 SSH 执行入口
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：将复杂远程命令沉淀为 `bin/cluster_start_hdfs_yarn.sh`、`bin/cluster_p5_postcheck.sh` 等本地 Bash 脚本，再由 `bin/cluster_ssh.py run --script` 执行。
- 配置变更：无
- 数据修复：无

### 后续优化

- 需要补充的自动化检查：复杂远程命令禁止直接写在 PowerShell 一行中。
- 需要沉淀到项目文档的步骤：远程执行统一走 `cluster_ssh.py run --script`。
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无
- 影响的任务：P5 启动前封装步骤；未影响最终 P5 发布。
- 是否需要重跑：不需要

### 2026-06-09 P5 Hive 清理旧进程命令误匹配当前脚本

### 现象

- 时间：2026-06-09
- 项目：finance_bigdata
- 任务/脚本：`bin/cluster_start_hive.sh`
- 报错摘要：脚本停在 `cleanup old hive processes`，远程命令提前退出。
- 关键日志路径：终端输出 `===== cleanup old hive processes =====` 后退出。

### 判断

- 根因分类：进程清理命令匹配范围过宽
- 影响组件：Hive Metastore/HiveServer2 启动脚本
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：将 `pkill -f` 改为 `jps -l | awk ... | xargs -r kill`，只按 Java 主类清理 Hive 进程。
- 配置变更：无
- 数据修复：无

### 后续优化

- 需要补充的自动化检查：进程清理优先使用 `jps -l` 主类匹配，避免匹配当前 shell。
- 需要沉淀到项目文档的步骤：Hive 重启先列 PID，再停止明确目标。
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无
- 影响的任务：Hive 启动脚本第一次尝试；修正后 Hive 启动成功。
- 是否需要重跑：不需要

### 2026-06-09 P6 Kafka topic 命名产生指标名警告

### 现象

- 时间：2026-06-09
- 项目：finance_bigdata
- 任务/脚本：`bin/p6_cluster_realtime_demo.sh`
- 报错摘要：Kafka 创建 topic 时提示 topic 名同时包含点号 `.` 和下划线 `_`，可能导致指标名冲突。
- 关键日志路径：P6 执行终端输出；本轮 topic 为 `finance.transactions.hi_small.20260609_070436` 和 `finance.risk.events.20260609_070436`

### 判断

- 根因分类：命名规范警告
- 影响组件：Kafka topic metrics 命名
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：本轮 P6 已通过，未删除已生成 topic；后续脚本已改为使用短横线和无下划线时间戳，例如 `finance-transactions-hi-small-YYYYMMDDHHMMSS`
- 配置变更：无
- 数据修复：无

### 后续优化

- 需要补充的自动化检查：topic 名避免同时混用 `.` 和 `_`
- 需要沉淀到项目文档的步骤：Kafka topic 命名统一使用 `finance-*` 前缀和短横线分隔
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无
- 影响的任务：不影响本轮 P6 数据回放、Flink 处理或 Redis 写入
- 是否需要重跑：不需要

### 2026-06-09 P8 首次交付包文档生成不完整

### 现象

- 时间：2026-06-09
- 项目：finance_bigdata
- 任务/脚本：`bin/p8_build_delivery_package.ps1`
- 报错摘要：首次生成的 `p8_delivery_package_20260609_223741` 缺少 `delivery_index.md`，且 `phase_summary.md` 内容为空。
- 关键日志路径：`data/finance_bigdata/delivery_packages/p8_delivery_package_20260609_223741`

### 判断

- 根因分类：PowerShell Markdown 字符串转义问题和包体最终校验缺失
- 影响组件：P8 交付包生成脚本
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：将 Markdown 生成改为单引号 here-string，避免反引号被 PowerShell 解释为转义字符；增加必需文件存在性校验和包内大文件校验。
- 配置变更：无
- 数据修复：重新生成有效交付包 `p8_delivery_package_20260609_223950`

### 后续优化

- 需要补充的自动化检查：交付包生成后必须检查入口文件、阶段摘要、manifest 和大文件阈值。
- 需要沉淀到项目文档的步骤：`p8_delivery_package_20260609_223950` 才是有效交付包。
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无
- 影响的任务：仅影响首次 P8 包文档生成，不影响 P0-P7 证据。
- 是否需要重跑：不需要重跑 P0-P7；已重跑 P8 打包脚本。

### 2026-06-09 P9 金额分箱 Categorical 填充值失败

### 现象

- 时间：2026-06-09
- 项目：finance_bigdata
- 任务/脚本：`analysis/p9_label_eda.py`
- 报错摘要：`TypeError: Cannot setitem on a Categorical with a new category (0), set the categories first`
- 关键日志路径：终端输出；失败 run_dir：`data/finance_bigdata/runs/p9_model_baseline_20260609_231338`

### 判断

- 根因分类：Pandas Categorical 类型处理错误
- 影响组件：P9 标签 EDA 金额分箱输出
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：将 `amount_bin` 分类标签转为字符串，只对 `laundering_rate` 的缺失值填 0，避免整表 `fillna(0)` 写入分类列。
- 配置变更：无
- 数据修复：无；重新执行 P9。

### 后续优化

- 需要补充的自动化检查：EDA 输出前增加 Categorical 列和数值列分开填充检查。
- 需要沉淀到项目文档的步骤：Pandas 分箱结果不要直接整表填 0。
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无，未生成有效 EDA 结果。
- 影响的任务：P9 首次 EDA 执行失败。
- 是否需要重跑：需要重跑 P9；有效结果为 `p9_model_baseline_20260609_231710`。

### 2026-06-09 P9 本地模型训练多进程权限失败

### 现象

- 时间：2026-06-09
- 项目：finance_bigdata
- 任务/脚本：`analysis/p9_baseline_model.py`
- 报错摘要：`PermissionError: [WinError 5] 拒绝访问。`
- 关键日志路径：终端输出；失败 run_dir：`data/finance_bigdata/runs/p9_model_baseline_20260609_231421`

### 判断

- 根因分类：本地执行环境多进程权限限制
- 影响组件：scikit-learn/joblib 模型训练并行执行
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：将 Logistic Regression 和 Random Forest 的 `n_jobs` 固定为 `1`，避免 joblib 在 Windows 本地环境创建多进程管道。
- 配置变更：无
- 数据修复：无；重新执行 P9。

### 后续优化

- 需要补充的自动化检查：本地作品集 runner 默认单进程，集群或高配环境再显式开启并行。
- 需要沉淀到项目文档的步骤：本地建模优先保证可复现，不依赖多进程。
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无，EDA 和特征构建已完成但模型结果未生成。
- 影响的任务：P9 第二次模型训练失败。
- 是否需要重跑：需要重跑 P9；有效结果为 `p9_model_baseline_20260609_231710`。

### 2026-06-09 P9 初版模型指标失真

### 现象

- 时间：2026-06-09
- 项目：finance_bigdata
- 任务/脚本：`analysis/p9_feature_build.py`、`analysis/p9_baseline_model.py`
- 报错摘要：脚本执行成功但 PR-AUC 接近 1.0，测试集只有 260 行且负样本仅 7 行，特征重要性中出现标签衍生字段。
- 关键日志路径：失真 run_dir：`data/finance_bigdata/runs/p9_model_baseline_20260609_231507`

### 判断

- 根因分类：建模口径问题
- 影响组件：P9 特征工程、训练/测试切分、模型评估
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：从建模特征中移除 `laundering_event_count`、`risk_score_rule` 等标签衍生账户字段；将时间切分改为分层随机 75/25 切分；模型脚本优先读取特征表中的 `split` 列。
- 配置变更：无
- 数据修复：重新生成 P9 有效 run_dir：`data/finance_bigdata/runs/p9_model_baseline_20260609_231710`

### 后续优化

- 需要补充的自动化检查：模型训练前检查泄漏字段黑名单、训练/测试正负样本比例和测试集最小样本量。
- 需要沉淀到项目文档的步骤：P9 指标必须同时报告切分策略、样本量和泄漏排除边界。
- 需要新增的监控或告警：后续 P14 master validation 可加入特征泄漏自动扫描。

### 影响范围

- 影响的数据层：P9 建模特征表和模型评估结果。
- 影响的任务：P9 第三次执行结果不作为有效证据。
- 是否需要重跑：已重跑 P9；有效结果为 `p9_model_baseline_20260609_231710`。

### 2026-06-09 P10 Spark 日志混入 TSV 证据

### 现象

- 时间：2026-06-09
- 项目：finance_bigdata
- 任务/脚本：`bin/p10_cluster_feature_parity.sh`
- 报错摘要：首次 P10 执行返回 PASS，但 `row_parity.tsv`、`numeric_parity.tsv`、`categorical_parity.tsv` 中混入 Spark/Hive stdout 日志行。
- 关键日志路径：非最终 run_dir：`data/finance_bigdata/runs/p10_feature_parity_20260609_084100`

### 判断

- 根因分类：证据文件输出清洗不足
- 影响组件：P10 Spark SQL 查询结果落盘
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：`run_query` 先将 Spark stdout 写入 raw 文件，再过滤时间戳日志、WARNING、SLF4J 等非数据行后写入 TSV；`schema_parity.tsv` 同步增加过滤。
- 配置变更：无
- 数据修复：重新执行 P10，生成有效 run_dir：`data/finance_bigdata/runs/p10_feature_parity_20260609_084412`

### 后续优化

- 需要补充的自动化检查：所有 Spark SQL 证据文件生成后检查是否包含日志行或非 TSV 数据行。
- 需要沉淀到项目文档的步骤：Spark CLI 输出需要区分 raw 日志和最终证据 TSV。
- 需要新增的监控或告警：P14 master validation 可加入证据文件格式扫描。

### 影响范围

- 影响的数据层：无，Iceberg 数据和特征口径未受影响。
- 影响的任务：P10 首次证据文件不作为最终证据。
- 是否需要重跑：已重跑 P10；有效结果为 `p10_feature_parity_20260609_084412`。

### 2026-06-11 P11 执行前实时组件未启动

### 现象

- 时间：2026-06-11
- 项目：finance_bigdata
- 任务/脚本：`bin/cluster_check_realtime_services.sh`
- 报错摘要：Kafka 9092 无法连接，Flink 8081 拒绝连接，YARN ResourceManager 8032 无响应；Redis 返回 `PONG`。
- 关键日志路径：本轮终端输出；后续有效 run_dir：`data/finance_bigdata/runs/p11_realtime_scoring_contract_20260611_011424`

### 判断

- 根因分类：虚拟机组件未启动或未完整启动
- 影响组件：Kafka、Flink、YARN
- 是否影响平台底座：是，属于本轮执行前的平台组件状态问题；未污染业务数据。

### 修正

- 执行命令或代码变更：先执行 `bin/cluster_start_hdfs_yarn.sh` 拉起 HDFS/YARN，再执行 `bin/cluster_start_realtime_services.sh` 拉起 Kafka、Redis、Flink，随后重新运行实时组件检查和 P11。
- 配置变更：无
- 数据修复：无

### 后续优化

- 需要补充的自动化检查：P11 runner 可在启动前增加 Kafka/Flink/YARN readiness gate，失败时明确提示启动脚本。
- 需要沉淀到项目文档的步骤：虚拟机重启后先按 `虚拟机集群启动顺序.txt` 或项目启动脚本拉起基础组件，再执行 P11。
- 需要新增的监控或告警：可在 P14 master validation 中加入 Kafka/Flink/YARN 端口和 CLI 双重检查。

### 影响范围

- 影响的数据层：无
- 影响的任务：仅影响 P11 执行前检查；启动组件后 P11 正常 PASS。
- 是否需要重跑：已执行 P11；有效结果为 `p11_realtime_scoring_contract_20260611_011424`。

### 2026-06-11 P12 Trino CLI 固定路径不存在

### 现象

- 时间：2026-06-11
- 项目：finance_bigdata
- 任务/脚本：`bin/p12_cluster_query_layer_validation.sh`
- 报错摘要：首次 P12 运行中所有 Trino 查询失败，错误为 `timeout: 无法运行命令 “/export/server/trino/bin/trino”: 没有那个文件或目录`。
- 关键日志路径：`data/finance_bigdata/runs/p12_query_layer_validation_20260611_012914/trino_nodes.err`、`data/finance_bigdata/runs/p12_query_layer_validation_20260611_012914/trino_query_status.tsv`

### 判断

- 根因分类：集群工具路径假设错误
- 影响组件：Trino CLI 查询层验证
- 是否影响平台底座：否；HDFS/YARN/Hive 正常，Doris smoke 正常，问题集中在 P12 脚本对 Trino CLI 路径的假设。

### 修正

- 执行命令或代码变更：`bin/p12_cluster_query_layer_validation.sh` 增加 `find_trino_cli`，按 `/usr/local/bin/trino`、`/export/server/trino-481/client/trino-cli`、`/export/server/trino-481/client/trino-client`、`/export/server/trino/bin/trino` 顺序自动发现可执行文件。
- 配置变更：无
- 数据修复：无；首次失败 run_dir 不作为有效 P12 证据。

### 后续优化

- 需要补充的自动化检查：查询层脚本在执行 SQL 前必须记录 CLI 路径并检查可执行权限。
- 需要沉淀到项目文档的步骤：Trino catalog 使用 `iceberg.finance_bigdata`，CLI 路径由脚本自动发现，不手工写死。
- 需要新增的监控或告警：P14 master validation 可增加 Trino CLI 路径和 server endpoint 双重检查。

### 影响范围

- 影响的数据层：无
- 影响的任务：P12 首次 Trino 查询验证失败；Doris smoke 不受影响。
- 是否需要重跑：已重跑 P12；有效结果为 `p12_query_layer_validation_20260611_013546`。

### 2026-06-11 P12 awk 行数统计表达式被解析为重定向

### 现象

- 时间：2026-06-11
- 项目：finance_bigdata
- 任务/脚本：`bin/p12_cluster_query_layer_validation.sh`
- 报错摘要：修正 Trino CLI 路径后，Trino 查询行数统计中的 `awk 'END {print NR > 0 ? NR - 1 : 0}'` 被 awk 按输出重定向表达式解析，导致脚本未形成有效 P12 证据。
- 关键日志路径：本轮终端输出；未形成最终本地有效 run_dir。

### 判断

- 根因分类：脚本表达式优先级问题
- 影响组件：P12 Trino 查询结果行数统计
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：将行数统计改为 `awk 'END {print (NR > 0 ? NR - 1 : 0)}'`，用括号明确三元表达式优先级。
- 配置变更：无
- 数据修复：无；修正脚本后重新执行 P12。

### 后续优化

- 需要补充的自动化检查：Bash 脚本新增 `bash -n` 语法检查，并对关键 TSV 行数统计做 smoke。
- 需要沉淀到项目文档的步骤：CLI 查询结果的 header 行扣减必须使用带括号的 awk 三元表达式。
- 需要新增的监控或告警：P14 master validation 可增加证据 TSV 行数与状态文件一致性检查。

### 影响范围

- 影响的数据层：无
- 影响的任务：P12 第二次尝试未形成最终有效证据。
- 是否需要重跑：已重跑 P12；有效结果为 `p12_query_layer_validation_20260611_013546`。

### 2026-06-11 P13 PowerShell here-string 与 JavaScript 模板占位冲突

### 现象

- 时间：2026-06-11
- 项目：finance_bigdata
- 任务/脚本：`bin/p13_build_bi_dashboard_package.ps1`
- 报错摘要：PowerShell 解析脚本时报 `Use { instead of { in variable names.`，原因是 HTML 预览内 JavaScript 模板字符串包含 `${...}`。
- 关键日志路径：本轮终端解析检查输出；脚本文件 `bin/p13_build_bi_dashboard_package.ps1`

### 判断

- 根因分类：脚本生成 HTML 时的字符串转义问题
- 影响组件：P13 BI 包生成脚本
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：将 HTML 中的 JavaScript template literal 改为普通字符串拼接，避免 PowerShell 双引号 here-string 解析 `${...}`。
- 配置变更：无
- 数据修复：无；脚本解析通过后重新执行 P13。

### 后续优化

- 需要补充的自动化检查：所有生成 HTML/JS 的 PowerShell 脚本先执行 Parser 解析检查。
- 需要沉淀到项目文档的步骤：PowerShell here-string 内避免直接使用 JavaScript `${...}` 模板占位。
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无
- 影响的任务：P13 脚本首次解析失败，未生成有效包。
- 是否需要重跑：已修正并重跑；有效结果为 `p13_bi_dashboard_package_20260611_172808`。

### 2026-06-11 P13 首次 BI 包文档围栏和文件计数口径不严

### 现象

- 时间：2026-06-11
- 项目：finance_bigdata
- 任务/脚本：`bin/p13_build_bi_dashboard_package.ps1`
- 报错摘要：首次生成的 `p13_bi_dashboard_package_20260611_172652` 中 SQL 参考文档代码围栏被 PowerShell 反引号转义为双反引号，且文件计数未纳入最终生成的 `p13_status.tsv` 和 `p13_summary.md`。
- 关键日志路径：`data/finance_bigdata/bi_packages/p13_bi_dashboard_package_20260611_172652/dashboard_sql_reference.md`、`data/finance_bigdata/bi_packages/p13_bi_dashboard_package_20260611_172652/p13_status.tsv`

### 判断

- 根因分类：生成文档格式和验收统计口径问题
- 影响组件：P13 BI 包文档质量和状态摘要
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：SQL 参考文档改用 `~~~sql` 围栏；包体文件数按最终新增 `p13_status.tsv`、`p13_summary.md` 后的 22 个文件计数；重新生成有效包。
- 配置变更：无
- 数据修复：无；首次包不作为最终 P13 证据。

### 后续优化

- 需要补充的自动化检查：P13 包生成后扫描 Markdown 围栏、残留模板占位和包体文件计数。
- 需要沉淀到项目文档的步骤：`p13_bi_dashboard_package_20260611_172808` 才是有效 P13 包。
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无
- 影响的任务：仅影响首次 P13 包的展示文档质量，不影响 P11/P12 源证据。
- 是否需要重跑：已重跑 P13；有效结果为 `p13_bi_dashboard_package_20260611_172808`。

### 2026-06-11 P14 阶段判定表达式返回空值

### 现象

- 时间：2026-06-11
- 项目：finance_bigdata
- 任务/脚本：`bin/p14_finance_master_validation.ps1`
- 报错摘要：首次 P14 执行在 P6 阶段判定处失败，`Status-FromBool` 无法把空值转换为 Boolean。
- 关键日志路径：非最终 run_dir：`data/finance_bigdata/runs/p14_master_validation_20260611_184727`

### 判断

- 根因分类：PowerShell 表达式优先级和参数类型约束问题
- 影响组件：P14 总验收脚本
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：将阶段判定中的 `-and` 与 `-eq` 条件全部加括号，并把 `Status-FromBool` 改为接收普通值后显式转 Boolean。
- 配置变更：无
- 数据修复：无；P0-P13 既有证据未修改。

### 后续优化

- 需要补充的自动化检查：P14 脚本执行前保留 PowerShell Parser 检查，复杂布尔表达式必须显式加括号。
- 需要沉淀到项目文档的步骤：`p14_master_validation_20260611_184955` 才是有效 P14。
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无
- 影响的任务：仅影响 P14 首次脚本执行。
- 是否需要重跑：已重跑 P14；有效结果为 `p14_master_validation_20260611_184955`。

### 2026-06-11 P14 汇总阶段 List 合并类型不兼容

### 现象

- 时间：2026-06-11
- 项目：finance_bigdata
- 任务/脚本：`bin/p14_finance_master_validation.ps1`
- 报错摘要：第二次 P14 执行在最终汇总阶段报 `Argument types do not match`。
- 关键日志路径：非最终 run_dir：`data/finance_bigdata/runs/p14_master_validation_20260611_184833`

### 判断

- 根因分类：PowerShell 泛型 List 与数组合并方式不兼容
- 影响组件：P14 总验收汇总逻辑
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：取消将多个泛型 List 合并为单一数组，改为分别统计 phase、metric、boundary、delivery 的 FAIL 数量后求和。
- 配置变更：无
- 数据修复：无

### 后续优化

- 需要补充的自动化检查：汇总脚本避免混用泛型集合和 PowerShell 数组的 `+=`。
- 需要沉淀到项目文档的步骤：非最终 P14 run_dir 必须写入 `invalid_evidence_inventory.tsv`。
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无
- 影响的任务：P14 第二次执行未形成有效 PASS。
- 是否需要重跑：已重跑 P14；有效结果为 `p14_master_validation_20260611_184955`。

### 2026-06-11 P14 凭据扫描规则自命中

### 现象

- 时间：2026-06-11
- 项目：finance_bigdata
- 任务/脚本：`bin/p14_finance_master_validation.ps1`
- 报错摘要：第三次 P14 证据链、关键指标和交付 readiness 均 PASS，但边界扫描中 `password_secret_not_written` FAIL，命中点是 P14 脚本自身的扫描规则包含历史敏感值片段。
- 关键日志路径：非最终 run_dir：`data/finance_bigdata/runs/p14_master_validation_20260611_184903`

### 判断

- 根因分类：安全扫描规则自污染
- 影响组件：P14 边界扫描
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：移除硬编码敏感值片段，改为通用模式检查；重新扫描后命中数为 0。
- 配置变更：无
- 数据修复：无

### 后续优化

- 需要补充的自动化检查：扫描敏感词时规则本身不得把任何真实敏感值写入仓库脚本。
- 需要沉淀到项目文档的步骤：P14 边界扫描以有效 PASS run 的 `boundary_scan.tsv` 为准。
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无
- 影响的任务：P14 第三次执行为脚本自检误报，不作为有效总验收。
- 是否需要重跑：已重跑 P14；有效结果为 `p14_master_validation_20260611_184955`。

### 2026-06-13 P15 PowerShell 将远端 warning 当作 NativeCommandError

### 现象

- 时间：2026-06-13
- 项目：finance_bigdata
- 任务/脚本：`bin/p15_local_restart_readiness.ps1`
- 报错摘要：首次执行 P15 时，远端 YARN 配置 warning 经 `python` stderr 返回后被 PowerShell `$ErrorActionPreference = "Stop"` 当成 NativeCommandError，导致本地 runner 提前停止。
- 关键日志路径：非最终 run_dir：`data/finance_bigdata/runs/p15_restart_readiness_20260613_211319`

### 判断

- 根因分类：本地 runner 对 native command stderr 处理过严
- 影响组件：P15 本地执行入口
- 是否影响平台底座：否；服务启动脚本和集群状态未被破坏。

### 修正

- 执行命令或代码变更：`Invoke-Step` 中临时将 `$ErrorActionPreference` 调整为 `Continue`，把 native stdout/stderr 全部转为文本写入 `.out` 文件，再根据 `$LASTEXITCODE` 判定步骤状态。
- 配置变更：无
- 数据修复：无；重新执行 P15。

### 后续优化

- 需要补充的自动化检查：所有 PowerShell runner 调用 Python/SSH 时，应把远端 warning 记录为日志而不是直接中断。
- 需要沉淀到项目文档的步骤：`p15_restart_readiness_20260613_211415` 才是有效 P15。
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无
- 影响的任务：P15 首次本地 runner 未完整生成证据。
- 是否需要重跑：已重跑 P15；有效结果为 `p15_restart_readiness_20260613_211415`。

### 2026-06-13 P16 本地 py_compile 写入 pycache 被拒绝

### 现象

- 时间：2026-06-13
- 项目：finance_bigdata
- 任务/脚本：`python -B -m py_compile analysis\p16_model_explainability.py`
- 报错摘要：Windows 拒绝写入或重命名 `analysis\__pycache__\p16_model_explainability.cpython-313.pyc`。
- 关键日志路径：本轮终端输出；无独立日志。

### 判断

- 根因分类：本地 Python 字节码缓存写入权限问题
- 影响组件：P16 语法检查命令
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：改用 `python -B -c "compile(...)"` 做不落盘语法检查；P16 runner 继续使用 `python -B`。
- 配置变更：无
- 数据修复：无

### 后续优化

- 需要补充的自动化检查：本地 Python 脚本语法检查统一使用不落盘 `compile()`。
- 需要沉淀到项目文档的步骤：P16 与 P0 一样遵循 `PYTHONDONTWRITEBYTECODE=1`。
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无
- 影响的任务：仅影响 P16 语法检查方式，不影响 P16 输出。
- 是否需要重跑：不需要；P16 有效结果为 `p16_model_explainability_20260613_211955`。

### 2026-06-13 P18 首次包演示清单路径和文件计数口径不严

### 现象

- 时间：2026-06-13
- 项目：finance_bigdata
- 任务/脚本：`bin/p18_build_portfolio_final_package.ps1`
- 报错摘要：首次 P18 包 `p18_portfolio_final_package_20260613_212751` 返回 PASS 后复查发现，`final_demo_checklist.md` 中部分复制材料路径与实际目录不一致，`package_file_count` 未计入最终写入的 `p18_status.tsv` 和 `p18_summary.md`。
- 关键日志路径：非最终包：`data/finance_bigdata/portfolio_packages/p18_portfolio_final_package_20260613_212751`

### 判断

- 根因分类：交付包导航和统计口径不严
- 影响组件：P18 作品集最终交付包生成脚本
- 是否影响平台底座：否

### 修正

- 执行命令或代码变更：修正 `final_demo_checklist.md` 生成路径；补充复制 P17 `p17_summary.md` 和 `quality_check_results.tsv`；将最终文件数按已写入文件加 `p18_status.tsv`、`p18_summary.md` 后统计；重新执行 P18。
- 配置变更：无
- 数据修复：无；P13-P17 既有证据未修改。

### 后续优化

- 需要补充的自动化检查：P18 打包后应检查清单中的相对路径是否真实存在，并在状态文件生成后再复核最终文件数。
- 需要沉淀到项目文档的步骤：`p18_portfolio_final_package_20260613_213025` 才是有效 P18 包。
- 需要新增的监控或告警：无

### 影响范围

- 影响的数据层：无
- 影响的任务：仅影响首次 P18 包的展示导航和统计报告，不影响 P13-P17 源证据。
- 是否需要重跑：已重跑 P18；有效结果为 `p18_portfolio_final_package_20260613_213025`。

### 2026-07-03 P15v2 模块化恢复 readiness 首轮执行未通过

### 现象

- 时间：2026-07-03
- 项目：finance_bigdata_v2
- 任务/脚本：P15v2 模块化恢复 readiness；本轮新增或调整过的辅助脚本包括 `bin/p15v2_cluster_modular_restart_readiness.sh`、`bin/p15v2_local_modular_restart_readiness.ps1`、`bin/p15v2_cluster_start_monitoring.sh`、`bin/p15v2_status_probe.sh`、`bin/p15v2_fast_status_probe.sh`。
- 报错摘要：P15v2 readiness 未达到 PASS。首轮本地结果目录 `data/finance_bigdata_v2/runs/p15v2_modular_restart_readiness_20260702_224847` 中 `p15v2_status.tsv` 为 FAIL；远端记录目录为 `/home/common/tmp/finance_bigdata_project/runs/p15v2_modular_restart_readiness_20260702_075109`。
- 已确认的失败项：`base_platform_status=FAIL`、`p11v2_realtime_module_status=FAIL`、`p12v2_query_module_status=FAIL`、`monitoring_module_status=FAIL`、`postcheck_status=FAIL`、`iceberg_table_fail_count=7`、`p15v2_status=FAIL`。
- 已确认仍可用的组件：ClickHouse 可查，`finance_bigdata_v2.ads_account_risk_features` 记录数为 6375；Elasticsearch health 为 green，`finance-risk-events-v2` 记录数为 8109；Ranger Admin、Atlas Web/API、Flink 8081、ZooKeeper 2181、ClickHouse 8123/9000、Elasticsearch 9200 端口检查可达。
- 已确认未真正启动或不可达的组件：HBase Master 16000/16010、Trino coordinator 8080/18080、Prometheus 9090、Grafana 3000。
- 第二次本地启动目录 `data/finance_bigdata_v2/runs/p15v2_modular_restart_readiness_20260703_012049` 仅留下本地启动步骤证据；`local_steps.tsv` 显示启动步骤执行到 `start_prometheus_grafana` 后，`p15v2_cluster_modular_restart_readiness` 失败；未形成可接受的最终 P15v2 证据包。

### 判断

- 根因分类：模块化恢复脚本与部分服务实例状态问题并存。
- 影响组件：HBase Master、Trino coordinator、Prometheus、Grafana、Spark SQL/Iceberg 轻量计数、YARN postcheck 解析、PowerShell 到 SSH 的远端命令封装。
- 是否影响平台底座：影响 P15v2 readiness 判定；不改写 P11v2/P12v2/P13v2 已完成阶段的事实源结论。
- 已确认脚本问题 1：本地 PowerShell 脚本把 `if (...)` 直接写在 hashtable 字段值位置，触发 `if : The term 'if' is not recognized as the name of a cmdlet...`。
- 已确认脚本问题 2：远端 readiness 聚合中 `grep`/布尔状态函数的组合存在状态反转风险，可能把 fail 口径聚合错。
- 已确认脚本问题 3：YARN postcheck 解析 `Total number of applications (application-types: [], states: [RUNNING] and tags: []):0` 时误读出 `[],states`。
- 已确认脚本问题 4：PowerShell 一行式 `cluster_ssh.py run --command` 在包含管道、引号、端口模式时多次被本地 shell 误拆，例如出现 `:8080 : The term ':8080' is not recognized...`。
- 已确认运行问题 1：Spark SQL/Iceberg 表计数阶段因为 `spark.driver.bindAddress=127.0.0.1` 导致 YARN ApplicationMaster 回连失败，日志中出现 `Failed to connect to hadoop1/CLUSTER_NODE1_IP:37211`。
- 已确认运行问题 2：HBase ZooKeeper、RegionServer 有迹象存在，但 hadoop1 上未见 HMaster；HBase shell 报 `KeeperErrorCode = NoNode for /hbase/master`，16000/16010 不可达。
- 已确认运行问题 3：hadoop1 的 8080 被本地 ZooKeeper/Atlas embedded 相关 `QuorumPeerMain` 绑定，Trino launcher 显示 `Not running`；8080/18080 均未形成可访问 coordinator。
- 已确认运行问题 4：Prometheus/Grafana 启动脚本输出 `prometheus_ready_code=000`、`grafana_login_code=000`，Windows 侧 9090/3000 端口不可达。
- 已确认运行问题 5：部分 SSH/asyncssh 调用出现长时间等待或 `Login timeout expired`，不能把脚本超时当成服务启动成功。

### 修正

- 已完成的脚本层修正：在本地 PowerShell readiness 脚本中增加 `Status-FromBool` 辅助函数，替代 hashtable 字段中的 inline `if`。
- 已完成的脚本层修正：在远端 readiness 聚合脚本中增加 `no_fail_status` 口径，避免 fail 检测和布尔状态聚合反向。
- 已完成的脚本层修正：将复杂远端排查命令转为 `.sh` 脚本方式执行，减少 PowerShell 一行命令、引号、管道、端口模式引发的误拆风险。
- 已完成的服务修复 1：HBase Master 单独恢复成功。证据目录 `data/finance_bigdata_v2/runs/p15v2_service_repair_20260703_015213` 中 `hbase_master_repair.tsv` 全部 PASS，`finance_bigdata_v2` namespace、`finance_bigdata_v2:account_risk_state` 表和 P11v2 状态样本可读。
- 已完成的服务修复 2：Trino 不再抢占 8080。8080 运行时占用来自 Atlas embedded ZooKeeper/AdminServer 相关进程；P15v2 使用临时 coordinator `http://hadoop1:18080`，不杀 Atlas，不修改 V1 Trino 永久配置。
- 已完成的服务修复 3：Prometheus/Grafana 明确绑定 `CLUSTER_NODE1_IP:9090/3000`，Prometheus targets 只包含 Prometheus 自身和 Grafana metrics，不伪装 ClickHouse/Elasticsearch/HBase/Ranger/Atlas 指标。
- 已完成的脚本层修正：新增低内存顺序执行入口 `bin/p15v2_local_low_memory_readiness.ps1` 和 `bin/p15v2_cluster_low_memory_readiness.sh`，替代旧的全量同时拉起式 readiness。
- 已完成的脚本层修正：远端检查统一加 `timeout --kill-after` 或 `curl --max-time`，并让本地 `cluster_ssh.py` 使用 `--connect-timeout`、`--login-timeout`、`--command-timeout`，避免 SSH/远端命令无界等待。
- 已完成的脚本层修正：Kafka quorum 检查显式使用 JDK17，避免 `UnsupportedClassVersionError ... class file version 61.0 ... recognizes up to 52.0`。
- 已完成的脚本层修正：Trino coordinator 显式使用 JDK25，且等待 `/v1/info` 返回 `state=ACTIVE`、`starting=false` 后再执行 CLI 查询，避免 `SERVER_STARTING_UP` 阶段误判失败。
- 已完成的脚本层修正：HBase 样本读取不再只匹配 `column=state:`，改为匹配 P11v2 实际列族 `s:`、`r:`、`meta:`、`m:`。
- 已完成的脚本层修正：Prometheus targets 检查增加等待 scrape 完成逻辑；如果 target 存在但刚启动时短暂 `unknown`，不立即误判为 0。

### hadoop1 内存爆满处理

- 风险现象：hadoop1 只有约 12GB 内存且无 swap；重启后 Elasticsearch、Atlas、Atlas embedded Solr/ZooKeeper、Ranger Admin、ClickHouse 等重组件可能自动拉起，内存已接近或超过 60% 占用。旧脚本继续叠加 HDFS/YARN、Hive、Kafka、Flink、HBase、Trino、Prometheus/Grafana 后，SSH banner 曾出现长时间不返回，`cluster_ssh.py` 连接阶段超时。
- 判断：不能把 P15v2 设计成“所有 V2 组件同时常驻”的验收。P15v2 的正确目标是证明各模块能按需恢复和轻量验收，而不是证明 hadoop1 能承载全量组件并发。
- 处理原则：严格参考 `模块化启动示例_zh.md`，先启动当前运行目标的最小依赖；Spark/Flink、Trino、ClickHouse/Elasticsearch、Ranger/Atlas、Prometheus/Grafana 不做无关并发。
- 处理动作 1：新增 `low_memory_sequential` 执行模式。先验证重启后已自动启动的查询/治理重组件，再释放 ClickHouse、Elasticsearch、Ranger、Atlas；随后验证基础平台、P11v2 实时状态模块、Trino/Iceberg、监控模块和备用组件。
- 处理动作 2：每个模块前后写入 `memory_guard.tsv`、`resource_usage_snapshots.tsv`、`release_actions.tsv`，并以 `MemAvailable_MB < 2048` 作为 WARN 门槛。
- 处理动作 3：验证重组件后释放它们。最终 accepted run 中 `release_actions.tsv` 记录 `finance-atlas`、`finance-ranger-admin`、`elasticsearch-finance-v2`、`clickhouse-server` 为 `released`，Flink/Kafka/HBase 和临时 Trino 为 best-effort released。
- 处理结果：accepted run `data/finance_bigdata_v2/runs/p15v2_modular_restart_readiness_20260703_035839/memory_guard.tsv` 显示内存全程无 WARN；`before=8205MB`、`after_query_search=5758MB`、`after_heavy_release=8214MB`、`after_p11=6368MB`、`after=8169MB`。
- 后续规范：P15v2/P17v2/P14v2 后续需要集群验证时，先做 `free -h` 和 `ss -lntp` 快照；除非明确需要，不要同时启动 ClickHouse、Elasticsearch、Ranger、Atlas、Kafka、Flink、HBase、Trino 和 Spark 作业。

### 最终结果

- 有效 P15v2 local run_dir：`data/finance_bigdata_v2/runs/p15v2_modular_restart_readiness_20260703_035839`。
- 有效 P15v2 Linux run_dir：`/home/common/tmp/finance_bigdata_project/runs/p15v2_modular_restart_readiness_20260703_035839`。
- 最终状态：`p15v2_status=PASS`，`p15v2_final_status=PASS`，执行模式为 `low_memory_sequential`。
- 关键状态：`base_platform_status=PASS`、`p11v2_realtime_module_status=PASS`、`p12v2_query_module_status=PASS`、`governance_module_status=PASS`、`monitoring_module_status=PASS`、`backup_components_status=PASS`、`postcheck_status=PASS`。
- 关键指标：Iceberg `dws_account_risk_features=515080`，ClickHouse ADS rows `6375`，Elasticsearch documents `8109`，Prometheus targets up `2`，YARN/Flink 残留 `0/0`，port binding fail count `0`，memory warning count `0`。
- 失败 run 仍作为诊断证据保留，不改写为 PASS：`p15v2_modular_restart_readiness_20260702_224847`、`p15v2_modular_restart_readiness_20260703_012049`、`p15v2_modular_restart_readiness_20260703_025913`、`p15v2_modular_restart_readiness_20260703_033425`、`p15v2_modular_restart_readiness_20260703_034320`。

### 后续优化

- 自动化检查：P15v2 后续只能使用低内存顺序入口或等价分模块脚本；不得恢复旧的“一次性启动全部 V2 组件”方式。
- 自动化检查：远端脚本必须显式设置 JDK 版本，Kafka 用 JDK17，Trino 用 JDK25，Hive Metastore 用 JDK8。
- 自动化检查：Trino 查询前必须等待 `/v1/info` 中 `starting=false`；Prometheus targets 检查必须允许初始 scrape 延迟。
- 自动化检查：每个远端服务检查必须有 timeout；如果 SSH banner 或 asyncssh login 超时，先恢复 hadoop1 sshd 或释放内存，不要继续叠加启动组件。
- 项目文档：`项目接口文档_zh.md` 与 `项目文档索引_zh.md` 已更新 P15v2 accepted run 和低内存执行边界。

### 影响范围

- 影响的数据层：不改写事实源，不重跑 P11v2，不把 ClickHouse 或 Elasticsearch 当事实源。
- 影响的任务：首轮 P15v2 readiness 未通过，但最终低内存顺序 run 已通过；P11v2、P12v2、P13v2 已沉淀证据不因本条记录改写。
- 是否需要重跑：无需重跑 P15v2；当前有效结果为 `p15v2_modular_restart_readiness_20260703_035839`。后续进入 P17v2/P14v2 时应读取这个 accepted evidence。

