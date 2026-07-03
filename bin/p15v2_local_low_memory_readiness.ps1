# P15v2 local orchestrator: low-memory sequential modular readiness.
param(
    [string]$RemoteRoot = "/home/common/tmp/finance_bigdata_project",
    [string]$PasswordFile = "PRIVATE_CREDENTIALS_ENV",
    [string]$LocalRunName = "",
    [string]$P11v2LocalRunDir = "data\finance_bigdata_v2\runs\p11v2_realtime_state_20260702_040833",
    [string]$P12v2LocalRunDir = "data\finance_bigdata_v2\runs\p12v2_clickhouse_es_validation_20260702_055525",
    [string]$P13v2PackageDir = "data\finance_bigdata_v2\bi_packages\p13v2_clickhouse_bi_package_20260702_213858"
)

$ErrorActionPreference = "Stop"
$env:PYTHONDONTWRITEBYTECODE = "1"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Read-EnvFile {
    param([string]$Path)
    $map = @{}
    Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object {
        if ($_ -match '^([A-Za-z0-9_]+)=(.*)$') {
            $map[$matches[1]] = $matches[2]
        }
    }
    return $map
}

function Read-Kv {
    param([string]$Path)
    $map = @{}
    Import-Csv -LiteralPath $Path -Delimiter "`t" | ForEach-Object {
        if ($_.metric) { $map[$_.metric] = $_.value }
        elseif ($_.check) { $map[$_.check] = $_.status }
    }
    return $map
}

function Test-PassStatus {
    param(
        [string]$Path,
        [string]$Key
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing status file: $Path"
    }
    $map = Read-Kv $Path
    if ($map[$Key] -ne "PASS") {
        throw "$Key is not PASS in $Path"
    }
}

function Status-FromBool {
    param([bool]$Value)
    if ($Value) { "PASS" } else { "FAIL" }
}

$passwordPath = Join-Path $root $PasswordFile
if (-not (Test-Path -LiteralPath $passwordPath)) {
    throw "Password file not found: $PasswordFile"
}
$secretMap = Read-EnvFile $passwordPath
if (-not $env:FINANCE_VM_PASSWORD) {
    if ($secretMap.ContainsKey("FINANCE_VM_PASSWORD")) {
        $env:FINANCE_VM_PASSWORD = $secretMap["FINANCE_VM_PASSWORD"]
    } elseif ($secretMap.ContainsKey("CLUSTER_HADOOP_COMMON_PASSWORD")) {
        $env:FINANCE_VM_PASSWORD = $secretMap["CLUSTER_HADOOP_COMMON_PASSWORD"]
    }
}
if (-not $env:FINANCE_VM_PASSWORD) {
    throw "FINANCE_VM_PASSWORD is not set and no cluster common password key was found"
}

$p11StatusPath = Join-Path $root (Join-Path $P11v2LocalRunDir "p11v2_state_summary.tsv")
$p12StatusPath = Join-Path $root (Join-Path $P12v2LocalRunDir "p12v2_status.tsv")
$p13StatusPath = Join-Path $root (Join-Path $P13v2PackageDir "p13v2_status.tsv")
Test-PassStatus $p12StatusPath "p12v2_status"
Test-PassStatus $p13StatusPath "p13v2_status"
$p11Map = Read-Kv $p11StatusPath
if ($p11Map["schema_invalid_event_count"] -ne "0") {
    throw "P11v2 source has invalid events: $($p11Map["schema_invalid_event_count"])"
}
if ([int]$p11Map["hbase_rows_written"] -le 0) {
    throw "P11v2 source has no HBase rows"
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
if ([string]::IsNullOrWhiteSpace($LocalRunName)) {
    $LocalRunName = "p15v2_modular_restart_readiness_$stamp"
}
$remoteRunStamp = $stamp
if ($LocalRunName -match '^p15v2_modular_restart_readiness_(.+)$') {
    $remoteRunStamp = $matches[1]
}
$RemoteRunDir = "$RemoteRoot/runs/p15v2_modular_restart_readiness_$remoteRunStamp"
$localRunDir = Join-Path $root "data\finance_bigdata_v2\runs\$LocalRunName"
New-Item -ItemType Directory -Force -Path $localRunDir | Out-Null

$stepsPath = Join-Path $localRunDir "local_steps.tsv"
"step`tstatus`tdetail" | Set-Content -LiteralPath $stepsPath -Encoding UTF8

function Invoke-Step {
    param(
        [string]$Name,
        [string[]]$Arguments,
        [string]$OutputFile,
        [switch]$AllowFail
    )
    $outputPath = Join-Path $localRunDir $OutputFile
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & python -B @Arguments 2>&1 | ForEach-Object { $_.ToString() }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $output | Set-Content -LiteralPath $outputPath -Encoding UTF8
    $status = if ($exitCode -eq 0) { "PASS" } else { "FAIL" }
    "$Name`t$status`t$outputPath" | Add-Content -LiteralPath $stepsPath -Encoding UTF8
    if (($exitCode -ne 0) -and (-not $AllowFail)) {
        throw "$Name failed with exit code $exitCode"
    }
    return $output
}

Write-Host "===== P15v2 low-memory remote readiness collection ====="
$remoteCommand = "REMOTE_ROOT='$RemoteRoot' RUN_STAMP='$remoteRunStamp' bash '$RemoteRoot/bin/p15v2_cluster_low_memory_readiness.sh'"
Invoke-Step "upload_p15v2_low_memory_script" @(".\bin\cluster_ssh.py", "upload", "--remote-dir", "$RemoteRoot/bin", ".\bin\p15v2_cluster_low_memory_readiness.sh") "upload_p15v2_low_memory_script.out" | Out-Null
$clusterOutput = Invoke-Step "p15v2_cluster_low_memory_readiness" @(".\bin\cluster_ssh.py", "--connect-timeout", "20", "--login-timeout", "20", "--command-timeout", "900", "run", "--command", $remoteCommand, "--stdin-file", $PasswordFile) "p15v2_cluster_low_memory_readiness.out" -AllowFail
$reportedRemoteRunDir = ($clusterOutput | Select-String -Pattern '^P15V2_REMOTE_RUN_DIR=' | Select-Object -Last 1).Line -replace '^P15V2_REMOTE_RUN_DIR=', ''
if (-not [string]::IsNullOrWhiteSpace($reportedRemoteRunDir)) {
    $RemoteRunDir = $reportedRemoteRunDir
}

$remoteFiles = @(
    "p15v2_summary.md",
    "p15v2_status.tsv",
    "steps.tsv",
    "module_sequence.tsv",
    "node_snapshot_before.tsv",
    "node_snapshot_after.tsv",
    "resource_usage_snapshots.tsv",
    "memory_guard.tsv",
    "release_actions.tsv",
    "base_platform_status.tsv",
    "iceberg_table_counts.tsv",
    "p11v2_realtime_module_status.tsv",
    "hbase_readiness.tsv",
    "p12v2_query_module_status.tsv",
    "clickhouse_readiness.tsv",
    "elasticsearch_readiness.tsv",
    "governance_module_status.tsv",
    "ranger_readiness.tsv",
    "atlas_readiness.tsv",
    "monitoring_module_status.tsv",
    "prometheus_grafana_readiness.tsv",
    "backup_components_status.tsv",
    "port_binding_scan.tsv",
    "postcheck.tsv",
    "hdfs_finance_ls.out",
    "yarn_nodes.out",
    "kafka_quorum.out",
    "flink_running_jobs.out",
    "hbase_readiness.out",
    "hbase_process_snapshot.txt",
    "trino_launcher_status.txt",
    "trino_cli_path.txt",
    "trino_nodes.tsv",
    "trino_finance_schema.tsv",
    "trino_account_risk_count.tsv",
    "clickhouse_database.tsv",
    "clickhouse_tables.tsv",
    "clickhouse_ads_count.tsv",
    "elasticsearch_health.json",
    "elasticsearch_count.json",
    "elasticsearch_search_sample.json",
    "ranger_6080_listener.txt",
    "ranger_5151_listener.txt",
    "atlas_listeners.txt",
    "atlas_status.json",
    "prometheus_targets.json",
    "opensearch_listener.txt"
)

$remotePaths = $remoteFiles | ForEach-Object { "$RemoteRunDir/$_" }
Write-Host "===== P15v2 download evidence ====="
Invoke-Step "download_p15v2_evidence" (@(".\bin\cluster_ssh.py", "download", "--local-dir", $localRunDir) + $remotePaths) "download_p15v2_evidence.out" | Out-Null

$p13PackagePath = Join-Path $root $P13v2PackageDir
$p13StatusMap = Read-Kv $p13StatusPath
$p13BoundaryPath = Join-Path $p13PackagePath "package_boundary_scan.tsv"
$p13BoundaryPass = $false
if (Test-Path -LiteralPath $p13BoundaryPath) {
    $boundaryRows = Import-Csv -LiteralPath $p13BoundaryPath -Delimiter "`t"
    $p13BoundaryPass = (@($boundaryRows | Where-Object { $_.status -ne "PASS" }).Count -eq 0)
}
$p13Checks = @()
$p13Checks += [pscustomobject]@{ check="p13v2_package_dir"; status=(Status-FromBool (Test-Path -LiteralPath $p13PackagePath)); value=$P13v2PackageDir; detail="latest accepted P13v2 package" }
$p13Checks += [pscustomobject]@{ check="dashboard_index"; status=(Status-FromBool (Test-Path -LiteralPath (Join-Path $p13PackagePath "dashboard_index.md"))); value="dashboard_index.md"; detail="required package entry" }
$p13Checks += [pscustomobject]@{ check="dashboard_preview"; status=(Status-FromBool (Test-Path -LiteralPath (Join-Path $p13PackagePath "dashboard_preview.html"))); value="dashboard_preview.html"; detail="required static preview" }
$p13Checks += [pscustomobject]@{ check="p13v2_status"; status=(Status-FromBool ($p13StatusMap["p13v2_status"] -eq "PASS")); value=$p13StatusMap["p13v2_status"]; detail="status from P13v2 package" }
$p13Checks += [pscustomobject]@{ check="p13v2_boundary_scan"; status=(Status-FromBool $p13BoundaryPass); value=$p13BoundaryPath; detail="no forbidden files or credential hits" }
$p13Checks | Export-Csv -LiteralPath (Join-Path $localRunDir "p13v2_bi_package_status.tsv") -Delimiter "`t" -NoTypeInformation

$remoteStatus = Read-Kv (Join-Path $localRunDir "p15v2_status.tsv")
$localP13Status = if (@($p13Checks | Where-Object { $_.status -ne "PASS" }).Count -eq 0) { "PASS" } else { "FAIL" }
$overall = if ($remoteStatus["p15v2_status"] -eq "PASS" -and $localP13Status -eq "PASS") { "PASS" } else { "FAIL" }

$finalStatusLines = @(
    "metric`tvalue",
    "run_name`t$LocalRunName",
    "local_run_dir`tdata/finance_bigdata_v2/runs/$LocalRunName",
    "remote_run_dir`t$RemoteRunDir",
    "execution_mode`tlow_memory_sequential",
    "remote_p15v2_status`t$($remoteStatus["p15v2_status"])",
    "p13v2_bi_package_status`t$localP13Status",
    "source_p11v2_run_dir`t$P11v2LocalRunDir",
    "source_p12v2_run_dir`t$P12v2LocalRunDir",
    "source_p13v2_package_dir`t$P13v2PackageDir",
    "p15v2_status`t$overall"
)
$finalStatusLines | Set-Content -LiteralPath (Join-Path $localRunDir "p15v2_final_status.tsv") -Encoding UTF8

$localSummary = @"
# P15v2 Local Low-Memory Modular Restart Readiness Summary

- Local run dir: ``data/finance_bigdata_v2/runs/$LocalRunName``
- Remote run dir: ``$RemoteRunDir``
- Execution mode: ``low_memory_sequential``
- Remote P15v2 status: ``$($remoteStatus["p15v2_status"])``
- P13v2 package status: ``$localP13Status``
- Overall status: ``$overall``

## Boundary

This run follows ``模块化启动示例.md`` and the P15v2 plan: modules are
validated sequentially and heavy services are released where possible. It does
not rebuild business data, rerun P11v2/P12v2, regenerate P13v2, start Doris, or
use OpenSearch as the main query/search component. No password values are
written to local evidence.
"@
$localSummary | Set-Content -LiteralPath (Join-Path $localRunDir "p15v2_local_summary.md") -Encoding UTF8

Write-Host "P15V2_LOCAL_RUN_DIR=$localRunDir"
Write-Host "P15V2_REMOTE_RUN_DIR=$RemoteRunDir"
Write-Host "P15V2_REMOTE_STATUS=$($remoteStatus["p15v2_status"])"
Write-Host "P15V2_P13_PACKAGE_STATUS=$localP13Status"
Write-Host "P15V2_STATUS=$overall"

if ($overall -ne "PASS") {
    exit 2
}

