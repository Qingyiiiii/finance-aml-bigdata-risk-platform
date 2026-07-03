# src 说明

Language: [中文](README_zh.md) | [English](README_en.md)

`src/` 承载本地离线数仓链路，围绕 HI-Small 样本完成 P0-P4 的数据检查、画像、ODS、DWD、DWS 产出。脚本以本地文件为执行边界，不启动 Spark/Flink/Kafka/Redis，也不声明集群发布状态。

## 模块职责

| 文件 | 阶段 | 定位 | 主要输入 | 主要输出 |
| --- | --- | --- | --- | --- |
| `finance_utils.py` | 公共工具 | 路径、字段、CSV、JSON、可选 Parquet 写入工具 | 配置、原始行数据 | 标准字段、通用读写函数 |
| `00_finance_preflight.py` | P0 | 原始文件与表头门禁 | `datas/HI-Small_*` | preflight JSON/TSV/Markdown |
| `01_finance_profile.py` | P1 | 数据画像与基础质量统计 | 交易、账户、模式文件 | profile summary/metrics |
| `02_finance_ods_sample.py` | P2 | ODS 小样本标准化 | 原始交易 CSV | ODS 样本 CSV/Parquet、schema |
| `03_finance_dwd_build.py` | P3 | DWD 明细与事件长表构建 | 原始交易/账户 CSV | DWD 交易明细、账户维表、交易事件长表 |
| `04_finance_dws_risk_kpi.py` | P4 | DWS 风险指标聚合 | P3 DWD 输出 | 分钟 KPI、账户画像、支付方式 KPI、大额候选 |

## 执行链路

```text
datas/HI-Small_*.csv
  -> P0 preflight
  -> P1 profile
  -> P2 ODS sample
  -> P3 DWD transactions/accounts/events
  -> P4 DWS risk KPI
  -> P5/P6/P9/P10/P11 downstream inputs
```

## 展示边界

- P0-P4 产物用于本地数据验证和下游样本输入，不等同于集群端发布结果。
- 默认范围限定在 `HI-Small`，不覆盖 `Medium/Large` 扩容场景。
- `risk_*` 字段表示规则口径或风控样例标签，不代表生产 AML 判定。
- 目录内不保留凭据、私有路径或环境专属配置。

