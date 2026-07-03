# P12v2 local orchestrator: run Trino + ClickHouse + Elasticsearch query/investigation validation.
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

function Invoke-RemoteStep {
    param(
        [string]$Name,
        [string[]]$Arguments
    )
    Write-Host "===== $Name ====="
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $rawOutput = & python -B @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $output = $rawOutput | ForEach-Object { $_.ToString() }
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    $output | Out-Host
    if ($exitCode -ne 0) {
        throw "$Name failed with exit code $exitCode"
    }
    return $output
}

Write-Host "===== P12v2 upload cluster script ====="
python -B .\bin\cluster_ssh.py upload --remote-dir "$RemoteRoot/bin" .\bin\p12v2_cluster_query_investigation.sh
if ($LASTEXITCODE -ne 0) {
    throw "P12v2 cluster script upload failed with exit code $LASTEXITCODE"
}

Invoke-RemoteStep "P12v2 start hdfs yarn" @(".\bin\cluster_ssh.py", "run", "--script", ".\bin\cluster_start_hdfs_yarn.sh") | Out-Null
Invoke-RemoteStep "P12v2 start postgresql" @(".\bin\cluster_ssh.py", "run", "--script", ".\bin\cluster_start_postgresql.sh", "--sudo-stdin") | Out-Null
Invoke-RemoteStep "P12v2 start hive" @(".\bin\cluster_ssh.py", "run", "--script", ".\bin\cluster_start_hive.sh") | Out-Null

if ([string]::IsNullOrWhiteSpace($RemoteRunDir)) {
    Write-Host "===== P12v2 cluster query investigation ====="
    $remoteCommand = "P11V2_SOURCE_RUN_DIR='$p11RemoteRunDir' bash '$RemoteRoot/bin/p12v2_cluster_query_investigation.sh'"
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
} else {
    $clusterExitCode = 0
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
    "trino_query_status.tsv",
    "trino_nodes.tsv",
    "trino_nodes.err",
    "trino_table_counts.tsv",
    "trino_table_counts.err",
    "clickhouse_ads_account_risk_features_source.tsv",
    "clickhouse_ads_account_risk_features_source.err",
    "clickhouse_query_status.tsv",
    "clickhouse_account_risk_topn.tsv",
    "clickhouse_account_risk_topn.err",
    "clickhouse_risk_score_buckets.tsv",
    "clickhouse_risk_score_buckets.err",
    "clickhouse_p11v2_risk_level_distribution.tsv",
    "clickhouse_p11v2_risk_level_distribution.err",
    "clickhouse_p11v2_payment_format_risk.tsv",
    "clickhouse_p11v2_payment_format_risk.err",
    "clickhouse_service.out",
    "clickhouse_version.txt",
    "clickhouse_version.err",
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
    "yarn_running_apps_after.out",
    "trino_launcher_status.txt",
    "trino_cli_path.txt",
    "hdfs_finance_ls.out",
    "yarn_nodes.out"
)

$remotePaths = $remoteFiles | ForEach-Object { "$RemoteRunDir/$_" }
Write-Host "===== P12v2 download evidence ====="
python -B .\bin\cluster_ssh.py download --local-dir $localRunDir @remotePaths
if ($LASTEXITCODE -ne 0) {
    throw "P12v2 evidence download failed with exit code $LASTEXITCODE"
}

$statusPath = Join-Path $localRunDir "p12v2_status.tsv"
$statusMap = @{}
Import-Csv -LiteralPath $statusPath -Delimiter "`t" | ForEach-Object {
    $statusMap[$_.metric] = $_.value
}

$localEvidenceStatus = if ($statusMap["p12v2_status"] -eq "PASS") { "PASS" } else { "FAIL" }
$overall = if (($clusterExitCode -eq 0) -and ($localEvidenceStatus -eq "PASS")) { "PASS" } else { "FAIL" }

$localSummary = @"
# P12v2 Local Query Investigation Summary

- Remote run dir: ``$RemoteRunDir``
- Local run dir: ``$localRunDir``
- P11v2 source local run: ``$p11RunPath``
- P11v2 source remote run: ``$p11RemoteRunDir``
- Trino status: ``$($statusMap["trino_status"])``
- ClickHouse status: ``$($statusMap["clickhouse_status"])``
- ClickHouse query pass count: ``$($statusMap["clickhouse_query_pass_count"])``
- Elasticsearch status: ``$($statusMap["elasticsearch_status"])``
- Elasticsearch health: ``$($statusMap["elasticsearch_health"])``
- Elasticsearch document count: ``$($statusMap["elasticsearch_document_count"])``
- Cluster exit code: ``$clusterExitCode``
- Local evidence status: ``$localEvidenceStatus``
- Overall status: ``$overall``

P12v2 validates Trino, ClickHouse, and Elasticsearch. It does not rerun P11v2 and does not use Doris or OpenSearch.
"@
$localSummary | Set-Content -LiteralPath (Join-Path $localRunDir "p12v2_local_summary.md") -Encoding UTF8

Write-Host "P12V2_LOCAL_RUN_DIR=$localRunDir"
Write-Host "P12V2_LOCAL_EVIDENCE_STATUS=$localEvidenceStatus"
Write-Host "P12V2_STATUS=$overall"

if ($overall -ne "PASS") {
    exit 2
}

