# Purpose: P13 BI 材料包生成入口，把 P11/P12 小型证据组织成 dashboard-ready 资料。
# Boundary: BI 包只做展示材料，不重跑查询、不复制原始数据或 Parquet 明细。
param(
    [string]$P12RunDir = "data\finance_bigdata\runs\p12_query_layer_validation_20260611_013546",
    [string]$P11RunDir = "data\finance_bigdata\runs\p11_realtime_scoring_contract_20260611_011424",
    [string]$OutputRoot = "data\finance_bigdata\bi_packages"
)

$ErrorActionPreference = "Stop"
$env:PYTHONDONTWRITEBYTECODE = "1"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Resolve-ProjectPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return (Join-Path $root $Path)
}

function Import-Tsv {
    param([string]$Path)
    return Import-Csv -LiteralPath $Path -Delimiter "`t"
}

function Get-StatusMap {
    param([string]$Path)
    $map = @{}
    Import-Tsv $Path | ForEach-Object {
        $map[$_.metric] = $_.value
    }
    return $map
}

function MarkdownTable {
    param(
        [array]$Rows,
        [string[]]$Columns,
        [string[]]$Headers = $Columns
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("| " + ($Headers -join " | ") + " |")
    $lines.Add("| " + (($Headers | ForEach-Object { "---" }) -join " | ") + " |")
    foreach ($row in $Rows) {
        $cells = foreach ($column in $Columns) {
            $value = [string]$row.$column
            $value = $value -replace "\|", "/"
            if ([string]::IsNullOrWhiteSpace($value)) { "-" } else { $value }
        }
        $lines.Add("| " + ($cells -join " | ") + " |")
    }
    return ($lines -join "`r`n")
}

function Write-Utf8 {
    param(
        [string]$Path,
        [string]$Text
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

$p12Path = Resolve-ProjectPath $P12RunDir
$p11Path = Resolve-ProjectPath $P11RunDir
$outputRootPath = Resolve-ProjectPath $OutputRoot

$requiredP12Files = @(
    "p12_summary.md",
    "p12_status.tsv",
    "trino_query_status.tsv",
    "trino_table_counts.tsv",
    "trino_payment_format_risk.tsv",
    "trino_large_transaction_topn.tsv",
    "trino_account_risk_topn.tsv",
    "trino_hourly_laundering_distribution.tsv",
    "doris_query_summary.tsv",
    "doris_status.tsv",
    "realtime_residue.tsv",
    "p11_redis_risk_sample.json"
)
$requiredP11Files = @(
    "p11_summary.md",
    "redis_contract_summary.tsv"
)

foreach ($file in $requiredP12Files) {
    $full = Join-Path $p12Path $file
    if (-not (Test-Path -LiteralPath $full)) {
        throw "Missing required P12 evidence file: $full"
    }
}
foreach ($file in $requiredP11Files) {
    $full = Join-Path $p11Path $file
    if (-not (Test-Path -LiteralPath $full)) {
        throw "Missing required P11 evidence file: $full"
    }
}

$p12Status = Get-StatusMap (Join-Path $p12Path "p12_status.tsv")
if ($p12Status["p12_status"] -ne "PASS") {
    throw "P12 status is not PASS: $($p12Status["p12_status"])"
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$runName = "p13_bi_dashboard_package_$stamp"
$packageDir = Join-Path $outputRootPath $runName
$dataDir = Join-Path $packageDir "copied_dashboard_data"
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

foreach ($file in $requiredP12Files) {
    Copy-Item -LiteralPath (Join-Path $p12Path $file) -Destination (Join-Path $dataDir $file) -Force
}
foreach ($file in $requiredP11Files) {
    Copy-Item -LiteralPath (Join-Path $p11Path $file) -Destination (Join-Path $dataDir $file) -Force
}

$tableCounts = Import-Tsv (Join-Path $p12Path "trino_table_counts.tsv")
$queryStatus = Import-Tsv (Join-Path $p12Path "trino_query_status.tsv")
$paymentRisk = Import-Tsv (Join-Path $p12Path "trino_payment_format_risk.tsv")
$largeTopn = Import-Tsv (Join-Path $p12Path "trino_large_transaction_topn.tsv")
$accountTopn = Import-Tsv (Join-Path $p12Path "trino_account_risk_topn.tsv")
$hourlyDistribution = Import-Tsv (Join-Path $p12Path "trino_hourly_laundering_distribution.tsv")
$dorisSummary = Import-Tsv (Join-Path $p12Path "doris_query_summary.tsv")
$redisResidue = Import-Tsv (Join-Path $p12Path "realtime_residue.tsv")
$redisContract = Import-Tsv (Join-Path $p11Path "redis_contract_summary.tsv")

$tableCountTable = MarkdownTable $tableCounts @("table_name", "expected_count", "actual_count", "status") @("Table", "Expected", "Actual", "Status")
$queryStatusTable = MarkdownTable $queryStatus @("query", "status", "rows") @("Query", "Status", "Rows")
$paymentTable = MarkdownTable $paymentRisk @("payment_format", "transaction_count", "laundering_count", "laundering_rate", "total_amount_paid") @("Payment Format", "Transactions", "Laundering", "Rate", "Total Amount")
$largeTable = MarkdownTable ($largeTopn | Select-Object -First 10) @("transaction_id", "transaction_minute", "from_account", "to_account", "amount_paid", "payment_currency", "payment_format", "is_laundering", "rule_hits") @("Transaction", "Minute", "From", "To", "Amount", "Currency", "Format", "Label", "Rules")
$accountTable = MarkdownTable ($accountTopn | Select-Object -First 10) @("account_number", "total_event_count", "debit_count", "credit_count", "out_amount", "counterparty_count", "laundering_event_count", "risk_score_rule") @("Account", "Events", "Debit", "Credit", "Out Amount", "Counterparties", "Label Events", "Rule Score")
$hourlyTable = MarkdownTable $hourlyDistribution @("transaction_hour", "transaction_count", "laundering_count", "laundering_rate", "total_amount_paid") @("Hour", "Transactions", "Laundering", "Rate", "Total Amount")
$dorisTable = MarkdownTable $dorisSummary @("metric", "metric_value") @("Metric", "Value")

$paymentJson = ($paymentRisk | Select-Object payment_format, transaction_count, laundering_count, laundering_rate, total_amount_paid | ConvertTo-Json -Depth 4 -Compress)
$hourlyJson = ($hourlyDistribution | Select-Object transaction_hour, transaction_count, laundering_count, laundering_rate, total_amount_paid | ConvertTo-Json -Depth 4 -Compress)
$accountJson = (($accountTopn | Select-Object -First 10 account_number, total_event_count, laundering_event_count, risk_score_rule, out_amount) | ConvertTo-Json -Depth 4 -Compress)
$largeJson = (($largeTopn | Select-Object -First 10 transaction_id, amount_paid, is_laundering, payment_format, rule_hits) | ConvertTo-Json -Depth 4 -Compress)

$dashboardIndex = @"
# Finance Big Data BI Dashboard Package

- Package: ``$runName``
- Source P12 run_dir: ``$P12RunDir``
- Source P11 run_dir: ``$P11RunDir``
- Trino status: ``$($p12Status["trino_status"])``
- Doris status: ``$($p12Status["doris_status"])``
- Business query pass count: ``$($p12Status["business_query_pass_count"])``
- P11 Redis key count: ``$($p12Status["p11_redis_key_count"])``
- Status: ``PASS``


P13 turns the verified P12 query-layer outputs into portfolio-ready BI materials. It does not copy raw data, large CSV files, or Parquet detail files. All dashboard data in this package comes from small P11/P12 evidence files.


- ``dashboard_preview.html``: standalone local dashboard preview.
- ``dashboard_metric_catalog.md``: metric definitions, data sources, and boundaries.
- ``dashboard_page_design.md``: recommended dashboard layout.
- ``dashboard_sql_reference.md``: Trino/Doris query reference.
- ``dashboard_demo_script.md``: demo talk track for portfolio presentation.
- ``copied_dashboard_data/``: small TSV/JSON evidence files copied from P11/P12.


- P12 source status is PASS.
- Trino table count validation is 7/7 PASS.
- Four business queries are available for BI display.
- Doris smoke query output is available.
- Package excludes raw transaction/account CSV files and Parquet detail files.
- P13 is not P14 master validation.
"@
Write-Utf8 (Join-Path $packageDir "dashboard_index.md") $dashboardIndex

$metricCatalog = @"
# Dashboard Metric Catalog


| Area | Source File | Query Layer |
| --- | --- | --- |
| Table inventory | ``copied_dashboard_data/trino_table_counts.tsv`` | Trino over ``iceberg.finance_bigdata`` |
| Payment risk | ``copied_dashboard_data/trino_payment_format_risk.tsv`` | Trino |
| Large transaction TopN | ``copied_dashboard_data/trino_large_transaction_topn.tsv`` | Trino |
| Account risk TopN | ``copied_dashboard_data/trino_account_risk_topn.tsv`` | Trino |
| Hourly laundering distribution | ``copied_dashboard_data/trino_hourly_laundering_distribution.tsv`` | Trino |
| Doris smoke metrics | ``copied_dashboard_data/doris_query_summary.tsv`` | Doris MySQL protocol |
| Realtime scoring residue | ``copied_dashboard_data/realtime_residue.tsv`` and ``copied_dashboard_data/redis_contract_summary.tsv`` | Redis/P11 evidence |


| Metric | Definition | Display Use |
| --- | --- | --- |
| Total transactions | ``COUNT(*)`` from ``dwd_finance_transactions`` | Global KPI card |
| Total accounts | ``COUNT(*)`` from ``dwd_finance_accounts`` | Global KPI card |
| Laundering count | ``SUM(is_laundering)`` by dimension | Risk KPI card and trend |
| Laundering rate | ``SUM(is_laundering) / COUNT(*)`` | Risk ranking |
| Payment format risk | Transaction count and laundering rate by payment method | Bar chart |
| Hourly risk distribution | Transaction and laundering counts by hour | Line or column chart |
| Large transaction candidates | Top transactions from DWS large transaction candidate table | Investigation table |
| Account risk score | Rule score and behavior aggregates by account | Account ranking table |
| Realtime risk keys | P11 Redis latest-state key count | Realtime health KPI |


$tableCountTable


$queryStatusTable


These metrics are for learning and portfolio demonstration. They are not production AML metrics, not an enterprise risk dashboard, and not P14 master validation.
"@
Write-Utf8 (Join-Path $packageDir "dashboard_metric_catalog.md") $metricCatalog

$pageDesign = @"
# Dashboard Page Design


Goal: show whether the query layer can support a broad AML overview.

Recommended widgets:

- KPI cards: total transactions, account rows, P11 realtime risk keys, Doris smoke status.
- Payment format risk bar chart.
- Hourly laundering distribution chart.
- Doris smoke metric table.


Goal: support drill-down style explanation for portfolio review.

Recommended widgets:

- High-risk account ranking.
- Large transaction candidate ranking.
- Redis realtime risk sample panel.
- Source table count validation panel.


Goal: make the project boundary clear.

Recommended widgets:

- P5 Iceberg source tables.
- P11 realtime scoring contract evidence.
- P12 Trino/Doris validation status.
- P13 package acceptance checklist.


$paymentTable


$accountTable


$largeTable
"@
Write-Utf8 (Join-Path $packageDir "dashboard_page_design.md") $pageDesign

$sqlReference = @"
# Dashboard SQL Reference


~~~sql
SHOW TABLES FROM iceberg.finance_bigdata;
~~~


~~~sql
SELECT 'dwd_finance_transactions' AS table_name, COUNT(*) AS actual_count
FROM iceberg.finance_bigdata.dwd_finance_transactions;
~~~


~~~sql
SELECT payment_format,
       transaction_count,
       laundering_count,
       ROUND(laundering_rate, 8) AS laundering_rate,
       CAST(total_amount_paid AS BIGINT) AS total_amount_paid
FROM iceberg.finance_bigdata.dws_payment_format_kpi
ORDER BY laundering_rate DESC, transaction_count DESC;
~~~


~~~sql
SELECT transaction_id,
       transaction_minute,
       from_account,
       to_account,
       amount_paid,
       payment_currency,
       payment_format,
       is_laundering,
       rule_hits
FROM iceberg.finance_bigdata.dws_large_transaction_candidates
ORDER BY amount_paid DESC
LIMIT 20;
~~~


~~~sql
SELECT account_number,
       total_event_count,
       debit_count,
       credit_count,
       CAST(out_amount AS BIGINT) AS out_amount,
       counterparty_count,
       laundering_event_count,
       cross_bank_event_count,
       cross_currency_event_count,
       risk_score_rule
FROM iceberg.finance_bigdata.dws_account_risk_features
ORDER BY risk_score_rule DESC, laundering_event_count DESC, out_amount DESC
LIMIT 20;
~~~


~~~sql
SELECT transaction_hour,
       COUNT(*) AS transaction_count,
       SUM(is_laundering) AS laundering_count,
       ROUND(CAST(SUM(is_laundering) AS DOUBLE) / COUNT(*), 8) AS laundering_rate,
       CAST(SUM(amount_paid) AS BIGINT) AS total_amount_paid
FROM iceberg.finance_bigdata.dwd_finance_transactions
GROUP BY transaction_hour
ORDER BY transaction_hour;
~~~


The P12 Doris smoke creates and queries ``finance_bigdata.p12_query_layer_metrics``.

$dorisTable
"@
Write-Utf8 (Join-Path $packageDir "dashboard_sql_reference.md") $sqlReference

$demoScript = @"
# Dashboard Demo Script


This dashboard package demonstrates that the finance big-data project can move from raw AML-style transactions to warehouse tables, realtime scoring evidence, query-layer validation, and BI-ready assets.


1. Start with ``dashboard_index.md`` and show the P13 boundary.
2. Open ``dashboard_preview.html`` to show the static BI preview.
3. Explain that P12 validates Trino over ``iceberg.finance_bigdata`` and that Doris smoke is recorded separately.
4. Use payment format risk to discuss dimension-level AML monitoring.
5. Use hourly laundering distribution to discuss temporal risk.
6. Use account and large transaction TopN tables to show investigation workflow.
7. Close with acceptance: no raw data copied, no Large data processed, and P13 is not P14 master validation.


- The portfolio value is the full data chain: DWD/DWS, Iceberg publication, realtime scoring, query layer, and BI artifacts.
- The BI package uses only small evidence files, so it is portable and review-friendly.
- Metrics are learning-oriented and rule-based; they are not production AML decisions.
"@
Write-Utf8 (Join-Path $packageDir "dashboard_demo_script.md") $demoScript

$previewHtml = @"
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>P13 Finance BI Dashboard Preview</title>
  <style>
    :root {
      --bg: #f6f7f9;
      --panel: #ffffff;
      --ink: #1f2933;
      --muted: #657083;
      --line: #d7dde6;
      --accent: #116a7b;
      --risk: #b42318;
      --ok: #247a45;
      --warn: #9a6700;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--ink);
      font-family: "Segoe UI", Arial, sans-serif;
      line-height: 1.45;
    }
    header {
      padding: 24px 32px 18px;
      background: #ffffff;
      border-bottom: 1px solid var(--line);
    }
    h1 { margin: 0 0 6px; font-size: 26px; font-weight: 650; }
    h2 { margin: 0 0 14px; font-size: 18px; font-weight: 650; }
    .sub { color: var(--muted); font-size: 14px; }
    main { padding: 22px 32px 36px; }
    .grid { display: grid; gap: 16px; }
    .kpis { grid-template-columns: repeat(4, minmax(0, 1fr)); }
    .two { grid-template-columns: minmax(0, 1.1fr) minmax(0, 0.9fr); margin-top: 16px; }
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 16px;
      min-width: 0;
    }
    .kpi-label { color: var(--muted); font-size: 13px; }
    .kpi-value { margin-top: 8px; font-size: 25px; font-weight: 700; }
    .status { color: var(--ok); }
    .bars { display: grid; gap: 9px; }
    .bar-row { display: grid; grid-template-columns: 110px 1fr 92px; gap: 10px; align-items: center; font-size: 13px; }
    .bar-track { height: 10px; background: #e8edf2; border-radius: 999px; overflow: hidden; }
    .bar-fill { height: 100%; background: var(--accent); }
    .bar-fill.risk { background: var(--risk); }
    table { width: 100%; border-collapse: collapse; font-size: 12px; }
    th, td { border-bottom: 1px solid var(--line); padding: 8px 6px; text-align: left; vertical-align: top; }
    th { color: var(--muted); font-weight: 650; }
    .chart { height: 220px; display: flex; align-items: end; gap: 5px; border-left: 1px solid var(--line); border-bottom: 1px solid var(--line); padding: 8px 4px 0; }
    .col { flex: 1; min-width: 10px; background: var(--accent); position: relative; }
    .col span { position: absolute; bottom: -20px; left: 50%; transform: translateX(-50%); font-size: 10px; color: var(--muted); }
    .note { margin-top: 12px; color: var(--muted); font-size: 12px; }
    @media (max-width: 980px) {
      main, header { padding-left: 16px; padding-right: 16px; }
      .kpis, .two { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <header>
    <h1>P13 Finance BI Dashboard Preview</h1>
    <div class="sub">Source: P12 Trino/Doris query-layer validation, package $runName</div>
  </header>
  <main>
    <section class="grid kpis">
      <div class="panel"><div class="kpi-label">P12 Status</div><div class="kpi-value status">$($p12Status["p12_status"])</div></div>
      <div class="panel"><div class="kpi-label">Trino Tables PASS</div><div class="kpi-value">7 / 7</div></div>
      <div class="panel"><div class="kpi-label">Business Queries</div><div class="kpi-value">$($p12Status["business_query_pass_count"]) / 4</div></div>
      <div class="panel"><div class="kpi-label">P11 Redis Keys</div><div class="kpi-value">$($p12Status["p11_redis_key_count"])</div></div>
    </section>

    <section class="grid two">
      <div class="panel">
        <h2>Payment Format Risk</h2>
        <div id="paymentBars" class="bars"></div>
      </div>
      <div class="panel">
        <h2>Hourly Laundering Distribution</h2>
        <div id="hourChart" class="chart"></div>
        <div class="note">Column height represents laundering count by transaction hour.</div>
      </div>
    </section>

    <section class="grid two">
      <div class="panel">
        <h2>High-Risk Account Top 10</h2>
        <div id="accountTable"></div>
      </div>
      <div class="panel">
        <h2>Large Transaction Top 10</h2>
        <div id="largeTable"></div>
      </div>
    </section>
  </main>
  <script>
    const paymentRisk = $paymentJson;
    const hourlyDistribution = $hourlyJson;
    const accountTop = $accountJson;
    const largeTop = $largeJson;

    const maxTx = Math.max(...paymentRisk.map(r => Number(r.transaction_count)));
    document.getElementById("paymentBars").innerHTML = paymentRisk.map(r => {
      const tx = Number(r.transaction_count);
      const rate = (Number(r.laundering_rate) * 100).toFixed(4) + "%";
      const width = Math.max(2, Math.round(tx / maxTx * 100));
      return '<div class="bar-row"><div>' + r.payment_format + '</div><div class="bar-track"><div class="bar-fill" style="width:' + width + '%"></div></div><div>' + rate + '</div></div>';
    }).join("");

    const maxLaundering = Math.max(...hourlyDistribution.map(r => Number(r.laundering_count)));
    document.getElementById("hourChart").innerHTML = hourlyDistribution.map(r => {
      const h = Math.max(2, Math.round(Number(r.laundering_count) / maxLaundering * 100));
      return '<div class="col" title="hour ' + r.transaction_hour + ': ' + r.laundering_count + '" style="height:' + h + '%"><span>' + r.transaction_hour + '</span></div>';
    }).join("");

    function table(rows, columns) {
      return '<table><thead><tr>' + columns.map(c => '<th>' + c.label + '</th>').join("") + '</tr></thead><tbody>' +
        rows.map(row => '<tr>' + columns.map(c => '<td>' + (row[c.key] ?? "") + '</td>').join("") + '</tr>').join("") +
      '</tbody></table>';
    }
    document.getElementById("accountTable").innerHTML = table(accountTop, [
      { key: "account_number", label: "Account" },
      { key: "risk_score_rule", label: "Score" },
      { key: "laundering_event_count", label: "Label Events" },
      { key: "out_amount", label: "Out Amount" }
    ]);
    document.getElementById("largeTable").innerHTML = table(largeTop, [
      { key: "transaction_id", label: "Transaction" },
      { key: "amount_paid", label: "Amount" },
      { key: "payment_format", label: "Format" },
      { key: "is_laundering", label: "Label" }
    ]);
  </script>
</body>
</html>
"@
Write-Utf8 (Join-Path $packageDir "dashboard_preview.html") $previewHtml

$copiedFiles = Get-ChildItem -LiteralPath $packageDir -Recurse -File
$largeFiles = $copiedFiles | Where-Object { $_.Length -gt 5MB }
$forbiddenFiles = $copiedFiles | Where-Object {
    $_.Name -match "HI-.*\.csv$" -or $_.Extension -in @(".parquet")
}
$requiredPackageFiles = @(
    "dashboard_index.md",
    "dashboard_metric_catalog.md",
    "dashboard_page_design.md",
    "dashboard_sql_reference.md",
    "dashboard_demo_script.md",
    "dashboard_preview.html"
)
$missingPackageFiles = $requiredPackageFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $packageDir $_)) }

$p13Status = "PASS"
if ($largeFiles.Count -gt 0 -or $forbiddenFiles.Count -gt 0 -or $missingPackageFiles.Count -gt 0) {
    $p13Status = "FAIL"
}

$maxBytes = ($copiedFiles | Measure-Object -Property Length -Maximum).Maximum
if ($null -eq $maxBytes) { $maxBytes = 0 }
$finalFileCount = $copiedFiles.Count + 2

$statusLines = New-Object System.Collections.Generic.List[string]
$statusLines.Add("metric`tvalue`tstatus")
$statusLines.Add("run_name`t$runName`tPASS")
$statusLines.Add("package_dir`t$packageDir`tPASS")
$statusLines.Add("source_p12_run_dir`t$P12RunDir`tPASS")
$statusLines.Add("source_p11_run_dir`t$P11RunDir`tPASS")
$statusLines.Add("p12_status`t$($p12Status["p12_status"])`t$(if ($p12Status["p12_status"] -eq "PASS") { "PASS" } else { "FAIL" })")
$statusLines.Add("trino_status`t$($p12Status["trino_status"])`t$(if ($p12Status["trino_status"] -eq "PASS") { "PASS" } else { "FAIL" })")
$statusLines.Add("doris_status`t$($p12Status["doris_status"])`t$(if ($p12Status["doris_status"] -eq "PASS") { "PASS" } else { "WARN" })")
$statusLines.Add("business_query_pass_count`t$($p12Status["business_query_pass_count"])`t$(if ([int]$p12Status["business_query_pass_count"] -eq 4) { "PASS" } else { "FAIL" })")
$statusLines.Add("package_file_count`t$finalFileCount`tPASS")
$statusLines.Add("max_file_bytes`t$maxBytes`t$(if ($largeFiles.Count -eq 0) { "PASS" } else { "FAIL" })")
$statusLines.Add("forbidden_raw_or_parquet_files`t$($forbiddenFiles.Count)`t$(if ($forbiddenFiles.Count -eq 0) { "PASS" } else { "FAIL" })")
$statusLines.Add("required_package_files_missing`t$($missingPackageFiles.Count)`t$(if ($missingPackageFiles.Count -eq 0) { "PASS" } else { "FAIL" })")
$statusLines.Add("p13_status`t$p13Status`t$p13Status")
Write-Utf8 (Join-Path $packageDir "p13_status.tsv") ($statusLines -join "`r`n")

$summary = @"
# P13 BI Dashboard Package Summary

- Run name: ``$runName``
- Package dir: ``$packageDir``
- Source P12 run_dir: ``$P12RunDir``
- Source P11 run_dir: ``$P11RunDir``
- Trino status: ``$($p12Status["trino_status"])``
- Doris status: ``$($p12Status["doris_status"])``
- Business query pass count: ``$($p12Status["business_query_pass_count"])``
- P11 Redis key count: ``$($p12Status["p11_redis_key_count"])``
- Package file count: ``$finalFileCount``
- Max file bytes: ``$maxBytes``
- Status: ``$p13Status``


P13 creates BI dashboard materials from already validated P11/P12 evidence. It does not rebuild the warehouse, does not submit Trino/Doris/Flink jobs, does not copy raw data, and is not P14 master validation.
"@
Write-Utf8 (Join-Path $packageDir "p13_summary.md") $summary

Write-Host "P13_PACKAGE_DIR=$packageDir"
Write-Host "P13_STATUS=$p13Status"
if ($p13Status -ne "PASS") {
    exit 2
}
