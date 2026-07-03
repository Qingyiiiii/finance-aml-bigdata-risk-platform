# Purpose: P12 本地编排入口，远程执行 Trino/Doris 查询层验证并下载证据。
# Boundary: P12 验证查询消费能力，不重建 P9/P10/P11。
param(
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

Write-Host "===== P12 start base services ====="
python -B .\bin\cluster_ssh.py run --script .\bin\cluster_start_hdfs_yarn.sh
if ($LASTEXITCODE -ne 0) {
    throw "P12 HDFS/YARN startup failed with exit code $LASTEXITCODE"
}
python -B .\bin\cluster_ssh.py run --script .\bin\cluster_start_postgresql.sh --sudo-stdin
if ($LASTEXITCODE -ne 0) {
    throw "P12 PostgreSQL startup failed with exit code $LASTEXITCODE"
}
python -B .\bin\cluster_ssh.py run --script .\bin\cluster_start_hive.sh
if ($LASTEXITCODE -ne 0) {
    throw "P12 Hive startup failed with exit code $LASTEXITCODE"
}

if ([string]::IsNullOrWhiteSpace($RemoteRunDir)) {
    Write-Host "===== P12 cluster query layer validation ====="
    $clusterOutput = python -B .\bin\cluster_ssh.py run --script .\bin\p12_cluster_query_layer_validation.sh 2>&1
    $clusterExitCode = $LASTEXITCODE
    $clusterOutput | Out-Host
    $RemoteRunDir = ($clusterOutput | Select-String -Pattern '^P12_RUN_DIR=' | Select-Object -Last 1).Line -replace '^P12_RUN_DIR=', ''
} else {
    $clusterExitCode = 0
}

if ([string]::IsNullOrWhiteSpace($RemoteRunDir)) {
    $RemoteRunDir = ($clusterOutput | Select-String -Pattern '^P12_CLUSTER_RUN_DIR=' | Select-Object -Last 1).Line -replace '^P12_CLUSTER_RUN_DIR=', ''
}
if ([string]::IsNullOrWhiteSpace($RemoteRunDir)) {
    throw "Could not determine P12 remote run directory"
}

if ([string]::IsNullOrWhiteSpace($LocalRunName)) {
    $LocalRunName = Split-Path -Leaf $RemoteRunDir
}

$localRunDir = Join-Path $root "data\finance_bigdata\runs\$LocalRunName"
New-Item -ItemType Directory -Force -Path $localRunDir | Out-Null

$remoteFiles = @(
    "p12_summary.md",
    "p12_status.tsv",
    "steps.tsv",
    "component_status.tsv",
    "trino_query_status.tsv",
    "trino_nodes.tsv",
    "trino_schemas.tsv",
    "trino_tables.tsv",
    "trino_table_counts.tsv",
    "trino_payment_format_risk.tsv",
    "trino_large_transaction_topn.tsv",
    "trino_account_risk_topn.tsv",
    "trino_hourly_laundering_distribution.tsv",
    "realtime_residue.tsv",
    "p11_redis_risk_sample.json",
    "doris_status.tsv",
    "doris_start_check.out",
    "doris_frontends.out",
    "doris_backends.out",
    "doris_be_processes.out",
    "doris_query_summary.tsv",
    "doris_query_summary.err",
    "postcheck.tsv",
    "yarn_running_apps_after.out",
    "trino_launcher_status.txt",
    "trino_cli_path.txt",
    "trino_nodes.err",
    "trino_schemas.err",
    "trino_tables.err",
    "trino_table_counts.err",
    "trino_payment_format_risk.err",
    "trino_large_transaction_topn.err",
    "trino_account_risk_topn.err",
    "trino_hourly_laundering_distribution.err"
)

$remotePaths = $remoteFiles | ForEach-Object { "$RemoteRunDir/$_" }
Write-Host "===== P12 download evidence ====="
python -B .\bin\cluster_ssh.py download --local-dir $localRunDir @remotePaths
if ($LASTEXITCODE -ne 0) {
    throw "P12 evidence download failed with exit code $LASTEXITCODE"
}

$statusPath = Join-Path $localRunDir "p12_status.tsv"
$statusMap = @{}
Import-Csv -LiteralPath $statusPath -Delimiter "`t" | ForEach-Object {
    $statusMap[$_.metric] = $_.value
}
$localEvidenceStatus = if ($statusMap["p12_status"] -eq "PASS") { "PASS" } else { "FAIL" }
$overall = if (($clusterExitCode -eq 0) -and ($localEvidenceStatus -eq "PASS")) { "PASS" } else { "FAIL" }

$localSummary = @"
# P12 Local Query Layer Validation Summary

- Remote run dir: ``$RemoteRunDir``
- Local run dir: ``$localRunDir``
- Trino status: ``$($statusMap["trino_status"])``
- Doris status: ``$($statusMap["doris_status"])``
- Business query pass count: ``$($statusMap["business_query_pass_count"])``
- P11 Redis key count: ``$($statusMap["p11_redis_key_count"])``
- Cluster exit code: ``$clusterExitCode``
- Local evidence status: ``$localEvidenceStatus``
- Overall status: ``$overall``

P12 validates the query layer. It does not rebuild P9/P10/P11 outputs and is not P14 master validation.
"@
$localSummary | Set-Content -LiteralPath (Join-Path $localRunDir "p12_local_summary.md") -Encoding UTF8

Write-Host "P12_LOCAL_RUN_DIR=$localRunDir"
Write-Host "TRINO_STATUS=$($statusMap["trino_status"])"
Write-Host "DORIS_STATUS=$($statusMap["doris_status"])"
Write-Host "P12_STATUS=$overall"

if ($overall -ne "PASS") {
    exit 2
}
