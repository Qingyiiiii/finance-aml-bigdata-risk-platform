# src

Language: [中文](README_zh.md) | [English](README_en.md)

`src/` contains the local offline warehouse pipeline for the finance AML sample project. It covers P0-P4 data checks, profiling, ODS normalization, DWD detail construction and DWS risk KPI aggregation based on the HI-Small sample. The scripts operate on local files only. They do not start Spark, Flink, Kafka or Redis, and they do not claim cluster deployment status.

### Module Responsibilities

| File | Phase | Purpose | Main Input | Main Output |
| --- | --- | --- | --- | --- |
| `finance_utils.py` | Shared utility | Project paths, field mapping, CSV, JSON and optional Parquet helpers | Configuration and raw rows | Standard fields and reusable read/write functions |
| `00_finance_preflight.py` | P0 | Raw file and header gate | `datas/HI-Small_*` | Preflight JSON, TSV and Markdown evidence |
| `01_finance_profile.py` | P1 | Data profiling and basic quality metrics | Transaction, account and pattern files | Profile summary and metrics |
| `02_finance_ods_sample.py` | P2 | ODS small-sample normalization | Raw transaction CSV | ODS sample CSV/Parquet and schema |
| `03_finance_dwd_build.py` | P3 | DWD transaction detail and event table build | Raw transaction/account CSV | DWD transaction detail, account dimension and transaction event table |
| `04_finance_dws_risk_kpi.py` | P4 | DWS risk KPI aggregation | P3 DWD outputs | Minute KPI, account profile, payment-format KPI and high-value candidates |

### Execution Flow

```text
datas/HI-Small_*.csv
  -> P0 preflight
  -> P1 profile
  -> P2 ODS sample
  -> P3 DWD transactions/accounts/events
  -> P4 DWS risk KPI
  -> P5/P6/P9/P10/P11 downstream inputs
```

### Public Boundary

- P0-P4 outputs are used for local data validation and downstream sample inputs. They are not equivalent to cluster-side release evidence.
- The default scope is limited to `HI-Small`. Medium/Large expansion is outside the default repository path.
- `risk_*` fields represent rule definitions or sample risk labels. They are not production AML decisions.
- This directory does not retain credentials, private paths or environment-specific secrets.

