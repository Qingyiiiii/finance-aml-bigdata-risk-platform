# streaming 说明

Language: [中文](README_zh.md) | [English](README_en.md)

`streaming/` 承载实时样例链路，覆盖 P6 规则闭环、P11 评分契约和 P11v2 状态流。目录内容围绕 Kafka 事件、Flink SQL、Redis latest-state 与 HBase 状态样本组织，用于展示实时风控链路的输入、处理和落地边界。

## 模块职责

| 文件 | 阶段 | 定位 | 主要输入 | 主要输出 |
| --- | --- | --- | --- | --- |
| `finance_make_replay_sample.py` | P6 | 交易事件回放样本生成 | DWD 交易 CSV | Kafka replay JSONL、summary |
| `finance_risk_rules_flink.sql` | P6 | Flink SQL 规则风控 | Kafka 交易 topic | Kafka 风险事件 topic |
| `finance_collect_risk_to_redis.py` | P6 | 风险事件 latest-state 收集 | 风险事件 JSONL | Redis latest-state、summary |
| `finance_make_scoring_contract_sample.py` | P11 | 实时评分契约样本生成 | P9 feature dataset、DWD 交易 Parquet | P11 scoring JSONL、summary |
| `finance_scoring_contract_flink.sql` | P11 | Flink SQL 评分契约处理 | P11 scoring input topic | P11 risk output topic |
| `finance_collect_contract_to_redis.py` | P11 | 契约校验与 latest-state 写入 | P11 风险事件 JSONL | Redis latest-state、invalid events、summary |
| `finance_make_p11v2_state_sample.py` | P11v2 | 状态流样本生成 | P11/P9/P10 产物 | P11v2 state JSONL、summary |
| `finance_p11v2_state_flink.sql` | P11v2 | Flink SQL 状态流处理 | P11v2 state topic | HBase state table |
| `finance_collect_p11v2_state.py` | P11v2 | P11v2 状态结果收集 | HBase/JSONL 状态数据 | state snapshot、summary |

## 执行链路

```text
P6:  DWD transactions -> replay JSONL -> Kafka/Flink rules -> risk events -> Redis latest-state
P11: P9 features + DWD transactions -> scoring contract JSONL -> Flink scoring -> Redis latest-state
P11v2: scoring/state samples -> Flink state stream -> HBase state table -> collected snapshot
```

## 展示边界

- `risk_score` 表示规则评分或契约评分，不等同于生产 ML 概率。
- schema-invalid 事件单独输出，不混入 Redis 正常 latest-state。
- Redis key 使用 `finance_bigdata:*` 命名空间，避免与其他项目状态混用。
- SQL 与脚本仅保留运行必要逻辑和模块级说明，不保留细粒度讲解、私人路径或凭据。

