# streaming

Language: [中文](README_zh.md) | [English](README_en.md)

`streaming/` contains the realtime sample pipeline for the finance AML project. It covers the P6 rule loop, the P11 scoring contract and the P11v2 state stream. The directory is organized around Kafka events, Flink SQL, Redis latest-state storage and HBase state samples, with explicit boundaries for realtime risk input, processing and landing.

### Module Responsibilities

| File | Phase | Purpose | Main Input | Main Output |
| --- | --- | --- | --- | --- |
| `finance_make_replay_sample.py` | P6 | Generate replay samples for transaction events | DWD transaction CSV | Kafka replay JSONL and summary |
| `finance_risk_rules_flink.sql` | P6 | Flink SQL rule-based risk scoring | Kafka transaction topic | Kafka risk event topic |
| `finance_collect_risk_to_redis.py` | P6 | Collect risk events into latest-state storage | Risk event JSONL | Redis latest-state and summary |
| `finance_make_scoring_contract_sample.py` | P11 | Generate realtime scoring contract samples | P9 feature dataset and DWD transaction Parquet | P11 scoring JSONL and summary |
| `finance_scoring_contract_flink.sql` | P11 | Process the scoring contract with Flink SQL | P11 scoring input topic | P11 risk output topic |
| `finance_collect_contract_to_redis.py` | P11 | Validate contract events and write latest-state data | P11 risk event JSONL | Redis latest-state, invalid events and summary |
| `finance_make_p11v2_state_sample.py` | P11v2 | Generate state-stream samples | P11/P9/P10 outputs | P11v2 state JSONL and summary |
| `finance_p11v2_state_flink.sql` | P11v2 | Process the state stream with Flink SQL | P11v2 state topic | HBase state table |
| `finance_collect_p11v2_state.py` | P11v2 | Collect P11v2 state results | HBase or JSONL state data | State snapshot and summary |

### Execution Flow

```text
P6:  DWD transactions -> replay JSONL -> Kafka/Flink rules -> risk events -> Redis latest-state
P11: P9 features + DWD transactions -> scoring contract JSONL -> Flink scoring -> Redis latest-state
P11v2: scoring/state samples -> Flink state stream -> HBase state table -> collected snapshot
```

### Public Boundary

- `risk_score` is a rule score or contract score. It is not a production ML probability.
- Schema-invalid events are written separately and must not be mixed into normal Redis latest-state data.
- Redis keys use the `finance_bigdata:*` namespace to avoid sharing state with other projects.
- SQL files and scripts keep only operational logic and module-level explanations. Fine-grained tutorial notes, private paths and credentials are not retained.

