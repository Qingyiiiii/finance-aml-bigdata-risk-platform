# Summary of Problem Investigation

Language: [中文](问题排查总结_zh.md) | [English](Summary-of-Problem-Investigation_en.md)

This document records project-level errors, diagnosis, fixes and follow-up optimization for the finance big-data project. Platform foundation issues should still be recorded in platform documents first. This file records only project-level issues.

### Record Template

#### Symptom

- Time:
- Project:
- Task/script:
- Error summary:
- Key log path:

#### Diagnosis

- Root-cause category:
- Affected components:
- Whether it affects the platform foundation:

#### Fix

- Command or code change:
- Configuration change:
- Data repair:

#### Follow-up Optimization

- Automated checks to add:
- Documentation steps to preserve:
- Monitoring or alerting to add:

#### Impact Scope

- Affected data layer:
- Affected tasks:
- Whether rerun is required:

### Recorded Issue Index

| Date | Issue | Public Summary | Final Scope |
| --- | --- | --- | --- |
| 2026-07-03 | P18v2 boundary wording triggered external-project keyword scan | Display-package boundary wording self-triggered the scan and was rewritten into neutral public wording | P14v2/P18v2 rerun required at the time |
| 2026-07-03 | P18v2 `GetRelativePath` runtime compatibility | Newer .NET API was not available in the current PowerShell runtime | Added compatible relative-path helper |
| 2026-07-03 | P14v2 `Select-String -Recurse` compatibility | Current PowerShell did not support the expected recursive parameter | Replaced with compatible recursive scanning |
| 2026-06-09 | P0 syntax check wrote to `pycache` and was denied | Compile check attempted to write cache files in a restricted environment | Adjusted syntax validation approach |
| 2026-06-09 | P3 account row count and unique-account count differed | Account rows and unique accounts are different metrics | Clarified metric definitions |
| 2026-06-09 | P5 PowerShell remote command quoting failed | Local shell parsing interfered with SSH commands | Reduced fragile inline quoting |
| 2026-06-09 | P5 Hive cleanup command matched the current script | Process cleanup pattern was too broad | Tightened cleanup scope |
| 2026-06-09 | P6 Kafka topic naming produced metric-name warning | Topic naming generated a warning but did not block execution | Kept functional topic flow and recorded the warning |
| 2026-06-09 | P8 initial delivery package was incomplete | First package was generated before script fixes were complete | Excluded the incomplete package |
| 2026-06-09 | P9 amount-bucket categorical fill failed | Pandas categorical fill value handling failed | Fixed bucket fill handling |
| 2026-06-09 | P9 local model training multiprocessing failed | Windows local multiprocessing permission blocked model training | Adjusted local model execution mode |
| 2026-06-09 | P9 first model metrics were invalid | Early feature set included leakage risk and split imbalance | Rebuilt accepted P9 evidence |
| 2026-06-09 | P10 Spark logs polluted TSV evidence | Spark stdout mixed with evidence output | Filtered stdout before writing TSV evidence |
| 2026-06-11 | P11 realtime components were not started before execution | Required Kafka/Flink/Redis state was missing | Added dependency checks and startup flow |
| 2026-06-11 | P12 fixed Trino CLI path did not exist | Script assumed a static CLI path | Added CLI discovery |
| 2026-06-11 | P12 `awk` row-count expression was parsed as redirection | Shell quoting caused row-count command parsing failure | Adjusted command quoting |
| 2026-06-11 | P13 PowerShell here-string conflicted with JavaScript template placeholders | Template syntax conflicted with PowerShell interpolation | Adjusted template generation |
| 2026-06-11 | P13 first BI package had weak fences and file-count logic | Initial package documentation and validation were incomplete | Excluded the first package |
| 2026-06-11 | P14 phase status expression returned empty values | Aggregation expression did not produce stable status text | Fixed status aggregation |
| 2026-06-11 | P14 list merge type was incompatible | PowerShell list merging produced type mismatch | Fixed merge logic |
| 2026-06-11 | P14 credential scan self-triggered | Scan rules matched their own documentation text | Neutralized scan wording |
| 2026-06-13 | P15 PowerShell treated remote warnings as `NativeCommandError` | Remote warning output was interpreted as command failure | Hardened remote command handling |
| 2026-06-13 | P16 local `py_compile` wrote to `pycache` and was denied | Compile validation attempted cache writes | Adjusted compile validation |
| 2026-06-13 | P18 first package had weak demo path and file-count reporting | Initial package boundary reporting was not strict enough | Excluded the first package |
| 2026-07-03 | P15v2 modular readiness first run failed | Low-memory cluster readiness required sequential modules and stronger timeouts | Accepted `low_memory_sequential` run passed |

### P15v2 Low-memory Readiness Public Summary

The accepted P15v2 result proves modular recovery readiness under a low-memory cluster strategy. It does not prove that all V2 services should remain resident at the same time.

Accepted local run:

```text
data/finance_bigdata_v2/runs/p15v2_modular_restart_readiness_20260703_035839
```

Accepted Linux run:

```text
/home/common/tmp/finance_bigdata_project/runs/p15v2_modular_restart_readiness_20260703_035839
```

Final status:

- `p15v2_status=PASS`
- `p15v2_final_status=PASS`
- execution mode: `low_memory_sequential`
- base platform, P11v2 realtime module, P12v2 query module, governance module, monitoring module, backup component recording and postcheck all passed

Key metrics:

- Iceberg `dws_account_risk_features=515080`
- ClickHouse ADS rows `6375`
- Elasticsearch documents `8109`
- Prometheus targets up `2`
- YARN/Flink residual jobs `0/0`
- port binding failures `0`
- memory warning count `0`

Public boundary:

- Do not rewrite fact sources.
- Do not rerun P11v2 because of this issue record.
- Do not treat ClickHouse or Elasticsearch as a source of truth.
- Do not restore the old strategy that starts all V2 components at the same time.
- Future P17v2/P14v2 work should read the accepted P15v2 evidence listed above.

