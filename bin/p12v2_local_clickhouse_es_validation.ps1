# P12v2 local orchestrator: run only ClickHouse + Elasticsearch validation.
param(
    [string]$P11v2LocalRunDir = "data\finance_bigdata_v2\runs\p11v2_realtime_state_20260702_040833",
    [string]$RemoteRoot = "/home/common/tmp/finance_bigdata_project",
    [string]$PasswordFile = "PRIVATE_CREDENTIALS_ENV",
    [string]$RemoteRunDir = "",
    [string]$LocalRunName = ""
)

$ErrorActionPreference = "Stop"
$env:PYTHONDONTWRITEBYTECODE = "1"

if (-not $env:FINANCE_VM_PASSWORD) {
    throw "FINANCE_VM_PASSWORD is not set"
}

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$p11RunPath = Join-Path $root $P11v2LocalRunDir
$p11SummaryPath = Join-Path $p11RunPath "p11v2_summary.md"
$p11StateSummaryPath = Join-Path $p11RunPath "p11v2_state_summary.tsv"
if (-not (Test-Path -LiteralPath $p11SummaryPath)) {
    throw "P11v2 summary not found: $p11SummaryPath"
}
if (-not (Test-Path -LiteralPath $p11StateSummaryPath)) {
    throw "P11v2 state summary not found: $p11StateSummaryPath"
}
if (-not (Test-Path -LiteralPath (Join-Path $root $PasswordFile))) {
    throw "Password file not found: $PasswordFile"
}

$p11Summary = Get-Content -LiteralPath $p11SummaryPath
$p11RemoteRunDir = ""
$p11RunLine = ($p11Summary | Where-Object { $_ -like "- Run dir:*" } | Select-Object -First 1)
if ($p11RunLine -match 'Run dir:\s+`([^`]+)`') {
    $p11RemoteRunDir = $Matches[1]
}
if ([string]::IsNullOrWhiteSpace($p11RemoteRunDir)) {
    throw "Could not parse P11v2 remote run dir from $p11SummaryPath"
}

$sourceMetrics = @{}
Import-Csv -LiteralPath $p11StateSummaryPath -Delimiter "`t" | ForEach-Object {
    $sourceMetrics[$_.metric] = $_.value
}
if ([int]$sourceMetrics["schema_invalid_event_count"] -ne 0) {
    throw "P11v2 source has schema_invalid_event_count=$($sourceMetrics["schema_invalid_event_count"])"
}
if ([int]$sourceMetrics["hbase_rows_written"] -le 0) {
    throw "P11v2 source has no HBase rows"
}

Write-Host "===== P12v2 upload ClickHouse/ES script ====="
python -B .\bin\cluster_ssh.py upload --remote-dir "$RemoteRoot/bin" .\bin\p12v2_cluster_clickhouse_es_validation.sh
if ($LASTEXITCODE -ne 0) {
    throw "P12v2 ClickHouse/ES cluster script upload failed with exit code $LASTEXITCODE"
}

if ([string]::IsNullOrWhiteSpace($RemoteRunDir)) {
    Write-Host "===== P12v2 ClickHouse/ES validation ====="
    $remoteCommand = "P11V2_SOURCE_RUN_DIR='$p11RemoteRunDir' bash '$RemoteRoot/bin/p12v2_cluster_clickhouse_es_validation.sh'"
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $rawClusterOutput = & python -B .\bin\cluster_ssh.py run --command $remoteCommand --stdin-file $PasswordFile 2>&1
        $clusterExitCode = $LASTEXITCODE
        $clusterOutput = $rawClusterOutput | ForEach-Object { $_.ToString() }
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    $clusterOutput | Out-Host
    $RemoteRunDir = ($clusterOutput | Select-String -Pattern '^P12V2_RUN_DIR=' | Select-Object -Last 1).Line -replace '^P12V2_RUN_DIR=', ''
    if ($clusterExitCode -ne 0) {
        throw "P12v2 ClickHouse/ES validation failed with exit code $clusterExitCode"
    }
}

if ([string]::IsNullOrWhiteSpace($RemoteRunDir)) {
    throw "Could not determine P12v2 remote run directory"
}

if ([string]::IsNullOrWhiteSpace($LocalRunName)) {
    $LocalRunName = Split-Path -Leaf $RemoteRunDir
}

$localRunDir = Join-Path $root "data\finance_bigdata_v2\runs\$LocalRunName"
New-Item -ItemType Directory -Force -Path $localRunDir | Out-Null

$remoteFiles = @(
    "p12v2_summary.md",
    "p12v2_status.tsv",
    "p12v2_steps.tsv",
    "component_status.tsv",
    "p11v2_source_reference.tsv",
    "clickhouse_query_results.tsv",
    "clickhouse_query_status.tsv",
    "clickhouse_high_risk_account_topn.tsv",
    "clickhouse_high_risk_account_topn.err",
    "clickhouse_risk_level_distribution.tsv",
    "clickhouse_risk_level_distribution.err",
    "clickhouse_payment_currency_risk_aggregation.tsv",
    "clickhouse_payment_currency_risk_aggregation.err",
    "clickhouse_risk_score_buckets.tsv",
    "clickhouse_risk_score_buckets.err",
    "clickhouse_ads_table_count.tsv",
    "clickhouse_ads_table_count.err",
    "clickhouse_events_table_count.tsv",
    "clickhouse_events_table_count.err",
    "clickhouse_ads_from_p11v2.tsv",
    "clickhouse_ads_generation.tsv",
    "clickhouse_service.out",
    "clickhouse_version.txt",
    "clickhouse_version.err",
    "clickhouse_database.out",
    "clickhouse_database.err",
    "clickhouse_tables.out",
    "clickhouse_tables.err",
    "clickhouse_load_ads.out",
    "clickhouse_load_ads.err",
    "clickhouse_load_events.out",
    "clickhouse_load_events.err",
    "elasticsearch_index_status.tsv",
    "elasticsearch_create_index.json",
    "elasticsearch_create_index.err",
    "elasticsearch_index_settings.json",
    "elasticsearch_index_settings.err",
    "elasticsearch_bulk.ndjson",
    "elasticsearch_bulk_response.json",
    "elasticsearch_bulk.err",
    "elasticsearch_refresh.json",
    "elasticsearch_refresh.err",
    "elasticsearch_health.json",
    "elasticsearch_health.err",
    "elasticsearch_count.json",
    "elasticsearch_count.err",
    "elasticsearch_search_sample.json",
    "elasticsearch_search_sample.err",
    "elasticsearch_service.out",
    "postcheck.tsv",
    "flink_jobs_after.txt",
    "yarn_running_apps_after.out"
)

$remotePaths = $remoteFiles | ForEach-Object { "$RemoteRunDir/$_" }
Write-Host "===== P12v2 download ClickHouse/ES evidence ====="
python -B .\bin\cluster_ssh.py download --local-dir $localRunDir @remotePaths
if ($LASTEXITCODE -ne 0) {
    throw "P12v2 evidence download failed with exit code $LASTEXITCODE"
}

$requiredFiles = @(
    "p12v2_summary.md",
    "p12v2_status.tsv",
    "p11v2_source_reference.tsv",
    "clickhouse_query_results.tsv",
    "clickhouse_query_status.tsv",
    "elasticsearch_index_status.tsv",
    "elasticsearch_search_sample.json",
    "postcheck.tsv"
)
foreach ($file in $requiredFiles) {
    $path = Join-Path $localRunDir $file
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required evidence file missing: $path"
    }
}

$statusPath = Join-Path $localRunDir "p12v2_status.tsv"
$statusMap = @{}
Import-Csv -LiteralPath $statusPath -Delimiter "`t" | ForEach-Object {
    $statusMap[$_.metric] = $_.value
}

if ($statusMap["p12v2_status"] -ne "PASS") {
    throw "P12v2 status is $($statusMap["p12v2_status"]); see $statusPath"
}

Write-Host "P12V2_LOCAL_RUN_DIR=$localRunDir"
Write-Host "P12V2_REQUIRED_EVIDENCE_STATUS=PASS"
Write-Host "P12V2_STATUS=$($statusMap["p12v2_status"])"

