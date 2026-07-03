# Purpose: P8 交付包冻结入口，只复制小型 summary 和说明材料。
# Boundary: 交付包不能复制原始 CSV、大 CSV、Parquet 明细或外部项目证据。
param(
    [string]$OutputRoot = "data/finance_bigdata/delivery_packages"
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$packageName = "p8_delivery_package_$stamp"
$packageDir = Join-Path $ProjectRoot (Join-Path $OutputRoot $packageName)
$copiedDir = Join-Path $packageDir "copied_summaries"
New-Item -ItemType Directory -Force -Path $packageDir, $copiedDir | Out-Null

function Project-Path {
    param([string]$Path)
    return (Join-Path $ProjectRoot $Path)
}

function Require-File {
    param([string]$Path)
    $full = Project-Path $Path
    if (-not (Test-Path -LiteralPath $full)) {
        throw "Required evidence file missing: $Path"
    }
    return $full
}

function Copy-Evidence {
    param(
        [string]$Phase,
        [string]$RelativePath
    )
    $source = Require-File $RelativePath
    $phaseDir = Join-Path $copiedDir $Phase
    New-Item -ItemType Directory -Force -Path $phaseDir | Out-Null
    $target = Join-Path $phaseDir (Split-Path -Leaf $RelativePath)
    Copy-Item -LiteralPath $source -Destination $target -Force
    return $target
}

$phaseEvidence = @(
    @{
        phase = "P0"
        title = "Raw data preflight"
        run_dir = "data/finance_bigdata/runs/p0_preflight_20260609_200713"
        status = "PASS"
        files = @("summary.tsv", "preflight_report.md", "file_inventory.tsv")
        note = "Confirmed HI-Small raw transaction/account/pattern files were readable."
    },
    @{
        phase = "P1"
        title = "Raw data profile"
        run_dir = "data/finance_bigdata/runs/p1_profile_20260609_200713"
        status = "PASS"
        files = @("profile_summary.md", "profile_metrics.tsv", "profile_summary.json")
        note = "Profiled 5,078,345 HI-Small transactions and account/pattern metadata."
    },
    @{
        phase = "P2"
        title = "ODS sample"
        run_dir = "data/finance_bigdata/runs/p2_ods_sample_20260609_200745"
        status = "PASS"
        files = @("ods_validation_summary.md", "ods_validation_summary.tsv", "ods_schema.md")
        note = "Created 100,000-row ODS sample and schema evidence."
    },
    @{
        phase = "P3"
        title = "DWD detail layer"
        run_dir = "data/finance_bigdata/runs/p3_dwd_build_20260609_203822"
        status = "PASS"
        files = @("dwd_summary.md", "dwd_summary.tsv", "steps.tsv")
        note = "Built DWD transactions, accounts and transaction events."
    },
    @{
        phase = "P4"
        title = "DWS risk KPI layer"
        run_dir = "data/finance_bigdata/runs/p4_dws_risk_kpi_20260609_204441"
        status = "PASS"
        files = @("dws_summary.md", "dws_summary.tsv", "steps.tsv")
        note = "Built minute, account, payment-format and large-transaction risk features."
    },
    @{
        phase = "P5"
        title = "Hive/Iceberg publish"
        run_dir = "data/finance_bigdata/runs/p5_hive_iceberg_publish_20260609_064034"
        status = "PASS"
        files = @("p5_summary.md", "count_validation.tsv", "steps.tsv")
        note = "Published 7 Iceberg tables under lakehouse.finance_bigdata."
    },
    @{
        phase = "P6"
        title = "Kafka/Flink/Redis realtime demo"
        run_dir = "data/finance_bigdata/runs/p6_realtime_demo_20260609_070436"
        status = "PASS"
        files = @("p6_summary.md", "redis_set_summary.tsv", "risk_events_sample.jsonl", "steps.tsv")
        note = "Replayed 10,000 transactions, generated 559 risk events, wrote 489 Redis latest-state keys."
    },
    @{
        phase = "P7"
        title = "Readiness snapshot"
        run_dir = "data/finance_bigdata/runs/p7_readiness_snapshot_20260609_072047"
        status = "PASS"
        files = @("p7_summary.md", "p7_local_summary.md", "component_status.tsv", "namespace_snapshot.tsv", "table_counts.tsv", "realtime_snapshot.tsv", "local_evidence_snapshot.tsv")
        note = "Captured readiness of platform components, namespaces, Iceberg tables, realtime residue and local evidence."
    }
)

$manifestRows = New-Object System.Collections.Generic.List[string]
$manifestRows.Add("phase`tstatus`trun_dir`tevidence_file`tpackage_copy`tnote")

foreach ($phase in $phaseEvidence) {
    foreach ($file in $phase.files) {
        $relative = "$($phase.run_dir)/$file"
        $target = Copy-Evidence -Phase $phase.phase -RelativePath $relative
        $packageRelative = Resolve-Path -LiteralPath $target -Relative
        $manifestRows.Add("$($phase.phase)`t$($phase.status)`t$($phase.run_dir)`t$relative`t$packageRelative`t$($phase.note)")
    }
}

$manifestPath = Join-Path $packageDir "evidence_manifest.tsv"
$manifestRows | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$deliveryIndex = @"
# Finance Big Data P8 Delivery Package

Generated at: $stamp


P8 delivery package status: `PASS`

This package freezes the first portfolio-ready finance big-data milestone after P0-P7. It is a delivery and demo package, not P14 master validation.


- Workspace: project workspace
- Dataset family: IBM AML synthetic transactions
- Current dataset scope: `HI-Small`
- Business namespace: `finance_bigdata`
- Linux project root: `/home/common/tmp/finance_bigdata_project`
- HDFS root: `/lakehouse/projects/finance_bigdata`
- Iceberg namespace: `lakehouse.finance_bigdata`
- Kafka/Redis prefix: `finance` / `finance_bigdata:*`


- P0-P7 evidence index and copied summaries.
- Architecture overview.
- Data lineage.
- Demo script.
- Known limits and next steps.


- Raw CSV files.
- Large CSV/Parquet detail outputs.
- Passwords, account secrets or one-time credentials.
- P14 master validation claim.
- Medium/Large dataset processing.


- `phase_summary.md`
- `evidence_manifest.tsv`
- `architecture_overview.md`
- `data_lineage.md`
- `demo_script.md`
- `known_limits_and_next_steps.md`
- `copied_summaries/`
"@
$deliveryIndex | Set-Content -LiteralPath (Join-Path $packageDir "delivery_index.md") -Encoding UTF8

$phaseSummary = @"
# P0-P7 Phase Summary

| Phase | Status | Result |
| --- | --- | --- |
| P0 | PASS | Raw file preflight confirmed HI-Small transaction/account/pattern files. |
| P1 | PASS | Profiled 5,078,345 transactions; laundering rate about 0.101943%. |
| P2 | PASS | Built 100,000-row ODS sample with standardized transaction columns. |
| P3 | PASS | Built DWD transactions, accounts and event-long table; account match rate 100%. |
| P4 | PASS | Built DWS minute KPI, account risk features, payment KPI and large-transaction candidates. |
| P5 | PASS | Published 7 Iceberg tables under `lakehouse.finance_bigdata`; all counts matched. |
| P6 | PASS | Replayed 10,000 messages through Kafka/Flink/Redis and produced 559 risk events. |
| P7 | PASS | Captured readiness snapshot: components, namespaces, tables, realtime evidence and P0-P6 local evidence. |


- DWD transaction rows: 5,078,345
- DWD event rows: 10,156,690
- DWS account feature rows: 515,080
- Large transaction candidates: 200,403
- Iceberg tables published: 7
- P6 replay messages: 10,000
- P6 risk events: 559
- Redis risk keys: 489


P8 is a packaging milestone. It does not rerun the pipeline, does not create new business data, and does not replace P14 master validation.
"@
$phaseSummary | Set-Content -LiteralPath (Join-Path $packageDir "phase_summary.md") -Encoding UTF8

$architecture = @"
# Architecture Overview


1. Local raw and profiling layer
   - Raw `HI-Small` CSV files live under `datas`.
   - P0-P2 validate file readability, profile data, and create a small ODS sample.

2. Local warehouse modeling layer
   - P3 produces DWD transactions, accounts and transaction events.
   - P4 produces DWS risk KPIs and features.

3. Cluster lakehouse layer
   - P5 publishes P3/P4 Parquet outputs into Iceberg through Spark.
   - Catalog/database: `lakehouse.finance_bigdata`.

4. Realtime demo layer
   - P6 writes JSON transaction messages to Kafka.
   - Flink SQL evaluates explainable risk rules.
   - Redis stores latest risk state by account.

5. Readiness layer
   - P7 verifies platform components, finance namespaces, table counts and realtime residue.


- No files are written to external project directories.
- Finance HDFS root is `/lakehouse/projects/finance_bigdata`.
- Finance database is `finance_bigdata`.
- Finance Kafka/Redis names use finance-specific prefixes.
- External project evidence is not used as finance project evidence.
"@
$architecture | Set-Content -LiteralPath (Join-Path $packageDir "architecture_overview.md") -Encoding UTF8

$lineage = @"
# Data Lineage

```text
Raw HI-Small CSV
  -> P0 preflight
  -> P1 profile
  -> P2 ODS sample
  -> P3 DWD
       dwd_finance_transactions
       dwd_finance_accounts
       dwd_finance_transaction_events
  -> P4 DWS
       dws_minute_transaction_kpi
       dws_account_risk_features
       dws_payment_format_kpi
       dws_large_transaction_candidates
  -> P5 Iceberg
       lakehouse.finance_bigdata.*
  -> P6 realtime demo
       Kafka input topic
       Flink risk rules
       Kafka risk topic
       Redis latest-state keys
  -> P7 readiness snapshot
```


- P5 count validation ties the Iceberg tables back to P3/P4 local evidence.
- P6 uses a 10,000-message sample and explainable rules. It is not a production risk model.
- P7 confirms current readiness and evidence integrity. It is not P14 master validation.
"@
$lineage | Set-Content -LiteralPath (Join-Path $packageDir "data_lineage.md") -Encoding UTF8

$demoScript = @"
# Demo Script


Introduce the project as a portfolio finance big-data workflow built on an existing three-node big-data platform. Emphasize that it is isolated from external project evidence.


Show that the current scope is IBM AML `HI-Small`, while Medium remains future scale-up data and Large was removed from this host due to hardware limits.


Open `phase_summary.md` and explain P0-P4:

- Raw preflight and profiling.
- ODS sample.
- DWD transactions/accounts/events.
- DWS risk features and KPIs.


Show P5 evidence:

- `copied_summaries/P5/count_validation.tsv`
- `lakehouse.finance_bigdata` contains 7 Iceberg tables.
- Counts match local P3/P4 results.


Show P6 evidence:

- 10,000 Kafka replay messages.
- 559 risk events.
- 489 Redis latest-state keys.
- Risk sample in `copied_summaries/P6/risk_events_sample.jsonl`.


Show P7 evidence:

- Component status all PASS.
- Iceberg table counts all PASS.
- Flink has no running job and YARN has no running application.


State the next recommended phase: P9 EDA, feature engineering and baseline model. Make clear P8 is a delivery package, not P14.
"@
$demoScript | Set-Content -LiteralPath (Join-Path $packageDir "demo_script.md") -Encoding UTF8

$limits = @"
# Limits And Boundaries


- This is a portfolio learning project, not a production financial system.
- P6 is a realtime small closed loop, not a production model service.
- P7 is a readiness snapshot, not P14 master validation.
- Large source files were removed from this host because the current machine is not suitable for that scale.
- Medium data is retained but not used in the current validated path.
- Current risk rules are explainable baseline rules, not trained fraud/AML models.


At the time of P7, Kafka, Redis and Flink services were running, but there were no Flink running jobs and no YARN running applications.


P9: data understanding, EDA, feature engineering and baseline model.

Recommended P9 outputs:

- Label distribution analysis.
- Entity/account behavior features.
- Train/test split strategy.
- Baseline classifier metrics.
- Model caveat document.
- Feature parity plan for warehouse-derived features.
"@
$limits | Set-Content -LiteralPath (Join-Path $packageDir "known_limits_and_next_steps.md") -Encoding UTF8

$summary = @"
# P8 Delivery Package Summary

- Package name: `$packageName`
- Package dir: `$packageDir`
- Status: `PASS`
- Evidence manifest: `evidence_manifest.tsv`
- Copied summaries: `copied_summaries`
- Boundary: P8 packaging only; not P14 master validation.
"@
$summary | Set-Content -LiteralPath (Join-Path $packageDir "p8_summary.md") -Encoding UTF8

"step`tstatus`tdetail" | Set-Content -LiteralPath (Join-Path $packageDir "steps.tsv") -Encoding UTF8
"validate_required_evidence`tPASS`tP0-P7 required evidence files exist" | Add-Content -LiteralPath (Join-Path $packageDir "steps.tsv") -Encoding UTF8
"copy_summaries`tPASS`tCopied summary and small evidence files only" | Add-Content -LiteralPath (Join-Path $packageDir "steps.tsv") -Encoding UTF8
"write_delivery_docs`tPASS`tGenerated delivery package markdown files" | Add-Content -LiteralPath (Join-Path $packageDir "steps.tsv") -Encoding UTF8

$deliveryIndexFixed = @'

Generated at: __STAMP__


P8 delivery package status: `PASS`

This package freezes the first portfolio-ready finance big-data milestone after P0-P7. It is a delivery and demo package, not P14 master validation.


- Workspace: project workspace
- Dataset family: IBM AML synthetic transactions
- Current dataset scope: `HI-Small`
- Business namespace: `finance_bigdata`
- Linux project root: `/home/common/tmp/finance_bigdata_project`
- HDFS root: `/lakehouse/projects/finance_bigdata`
- Iceberg namespace: `lakehouse.finance_bigdata`
- Kafka/Redis prefix: `finance` / `finance_bigdata:*`


- P0-P7 evidence index and copied summaries.
- Architecture overview.
- Data lineage.
- Demo script.
- Known limits and next steps.


- Raw CSV files.
- Large CSV/Parquet detail outputs.
- Passwords, account secrets or one-time credentials.
- P14 master validation claim.
- Medium/Large dataset processing.


- `phase_summary.md`
- `evidence_manifest.tsv`
- `architecture_overview.md`
- `data_lineage.md`
- `demo_script.md`
- `known_limits_and_next_steps.md`
- `copied_summaries/`
'@
($deliveryIndexFixed -replace '__STAMP__', $stamp) | Set-Content -LiteralPath (Join-Path $packageDir "delivery_index.md") -Encoding UTF8

$phaseSummaryFixed = @'

| Phase | Status | Result |
| --- | --- | --- |
| P0 | PASS | Raw file preflight confirmed HI-Small transaction/account/pattern files. |
| P1 | PASS | Profiled 5,078,345 transactions; laundering rate about 0.101943%. |
| P2 | PASS | Built 100,000-row ODS sample with standardized transaction columns. |
| P3 | PASS | Built DWD transactions, accounts and transaction events; account match rate 100%. |
| P4 | PASS | Built DWS minute KPI, account risk features, payment KPI and large-transaction candidates. |
| P5 | PASS | Published 7 Iceberg tables under `lakehouse.finance_bigdata`; all counts matched. |
| P6 | PASS | Replayed 10,000 messages through Kafka/Flink/Redis and produced 559 risk events. |
| P7 | PASS | Captured readiness snapshot: components, namespaces, tables, realtime evidence and P0-P6 local evidence. |


- DWD transaction rows: 5,078,345
- DWD event rows: 10,156,690
- DWS account feature rows: 515,080
- Large transaction candidates: 200,403
- Iceberg tables published: 7
- P6 replay messages: 10,000
- P6 risk events: 559
- Redis risk keys: 489


P8 is a packaging milestone. It does not rerun the pipeline, does not create new business data, and does not replace P14 master validation.
'@
$phaseSummaryFixed | Set-Content -LiteralPath (Join-Path $packageDir "phase_summary.md") -Encoding UTF8

$architectureFixed = @'


1. Local raw and profiling layer
   - Raw `HI-Small` CSV files live under `datas`.
   - P0-P2 validate file readability, profile data, and create a small ODS sample.

2. Local warehouse modeling layer
   - P3 produces DWD transactions, accounts and transaction events.
   - P4 produces DWS risk KPIs and features.

3. Cluster lakehouse layer
   - P5 publishes P3/P4 Parquet outputs into Iceberg through Spark.
   - Catalog/database: `lakehouse.finance_bigdata`.

4. Realtime demo layer
   - P6 writes JSON transaction messages to Kafka.
   - Flink SQL evaluates explainable risk rules.
   - Redis stores latest risk state by account.

5. Readiness layer
   - P7 verifies platform components, finance namespaces, table counts and realtime residue.


- No files are written to external project directories.
- Finance HDFS root is `/lakehouse/projects/finance_bigdata`.
- Finance database is `finance_bigdata`.
- Finance Kafka/Redis names use finance-specific prefixes.
- External project evidence is not used as finance project evidence.
'@
$architectureFixed | Set-Content -LiteralPath (Join-Path $packageDir "architecture_overview.md") -Encoding UTF8

$lineageFixed = @'

```text
Raw HI-Small CSV
  -> P0 preflight
  -> P1 profile
  -> P2 ODS sample
  -> P3 DWD
       dwd_finance_transactions
       dwd_finance_accounts
       dwd_finance_transaction_events
  -> P4 DWS
       dws_minute_transaction_kpi
       dws_account_risk_features
       dws_payment_format_kpi
       dws_large_transaction_candidates
  -> P5 Iceberg
       lakehouse.finance_bigdata.*
  -> P6 realtime demo
       Kafka input topic
       Flink risk rules
       Kafka risk topic
       Redis latest-state keys
  -> P7 readiness snapshot
```


- P5 count validation ties the Iceberg tables back to P3/P4 local evidence.
- P6 uses a 10,000-message sample and explainable rules. It is not a production risk model.
- P7 confirms current readiness and evidence integrity. It is not P14 master validation.
'@
$lineageFixed | Set-Content -LiteralPath (Join-Path $packageDir "data_lineage.md") -Encoding UTF8

$demoScriptFixed = @'


Introduce the project as a portfolio finance big-data workflow built on an existing three-node big-data platform. Emphasize that it is isolated from external project evidence.


Show that the current scope is IBM AML `HI-Small`, while Medium remains future scale-up data and Large was removed from this host due to hardware limits.


Open `phase_summary.md` and explain P0-P4:

- Raw preflight and profiling.
- ODS sample.
- DWD transactions/accounts/events.
- DWS risk features and KPIs.


Show P5 evidence:

- `copied_summaries/P5/count_validation.tsv`
- `lakehouse.finance_bigdata` contains 7 Iceberg tables.
- Counts match local P3/P4 results.


Show P6 evidence:

- 10,000 Kafka replay messages.
- 559 risk events.
- 489 Redis latest-state keys.
- Risk sample in `copied_summaries/P6/risk_events_sample.jsonl`.


Show P7 evidence:

- Component status all PASS.
- Iceberg table counts all PASS.
- Flink has no running job and YARN has no running application.


State the next recommended phase: P9 EDA, feature engineering and baseline model. Make clear P8 is a delivery package, not P14.
'@
$demoScriptFixed | Set-Content -LiteralPath (Join-Path $packageDir "demo_script.md") -Encoding UTF8

$limitsFixed = @'


- This is a portfolio learning project, not a production financial system.
- P6 is a realtime small closed loop, not a production model service.
- P7 is a readiness snapshot, not P14 master validation.
- Large source files were removed from this host because the current machine is not suitable for that scale.
- Medium data is retained but not used in the current validated path.
- Current risk rules are explainable baseline rules, not trained fraud/AML models.


At the time of P7, Kafka, Redis and Flink services were running, but there were no Flink running jobs and no YARN running applications.


P9: data understanding, EDA, feature engineering and baseline model.

Recommended P9 outputs:

- Label distribution analysis.
- Entity/account behavior features.
- Train/test split strategy.
- Baseline classifier metrics.
- Model caveat document.
- Feature parity plan for warehouse-derived features.
'@
$limitsFixed | Set-Content -LiteralPath (Join-Path $packageDir "known_limits_and_next_steps.md") -Encoding UTF8

$summaryFixed = @'

- Package name: `__PACKAGE_NAME__`
- Package dir: `__PACKAGE_DIR__`
- Status: `PASS`
- Evidence manifest: `evidence_manifest.tsv`
- Copied summaries: `copied_summaries`
- Boundary: P8 packaging only; not P14 master validation.
'@
$summaryFixed.Replace('__PACKAGE_NAME__', $packageName).Replace('__PACKAGE_DIR__', $packageDir) | Set-Content -LiteralPath (Join-Path $packageDir "p8_summary.md") -Encoding UTF8

$requiredPackageFiles = @(
    "delivery_index.md",
    "phase_summary.md",
    "evidence_manifest.tsv",
    "architecture_overview.md",
    "data_lineage.md",
    "demo_script.md",
    "known_limits_and_next_steps.md",
    "p8_summary.md",
    "steps.tsv"
)
foreach ($file in $requiredPackageFiles) {
    $full = Join-Path $packageDir $file
    if (-not (Test-Path -LiteralPath $full)) {
        throw "P8 package required file missing after generation: $file"
    }
    if ((Get-Item -LiteralPath $full).Length -le 3) {
        throw "P8 package required file is empty or invalid: $file"
    }
}

$largeCopied = Get-ChildItem -LiteralPath $packageDir -Recurse -File | Where-Object { $_.Length -gt 5MB }
if ($largeCopied) {
    throw "P8 package unexpectedly contains files larger than 5MB"
}

"validate_package_files`tPASS`tRequired package files exist and no copied file is larger than 5MB" | Add-Content -LiteralPath (Join-Path $packageDir "steps.tsv") -Encoding UTF8

Write-Host "P8_PACKAGE_DIR=$packageDir"
Write-Host "P8_STATUS=PASS"
