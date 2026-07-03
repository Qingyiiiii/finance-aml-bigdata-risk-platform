# Purpose: P15 本地编排入口，验证虚拟机重启后基础服务、实时服务和表证据恢复情况。
# Boundary: P15 是恢复 readiness，不替代 P14 总验收。
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

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
if ([string]::IsNullOrWhiteSpace($LocalRunName)) {
    $LocalRunName = "p15_restart_readiness_$stamp"
}
$localRunDir = Join-Path $root "data\finance_bigdata\runs\$LocalRunName"
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

Invoke-Step "start_hdfs_yarn" @(".\bin\cluster_ssh.py", "run", "--script", ".\bin\cluster_start_hdfs_yarn.sh") "start_hdfs_yarn.out" | Out-Null
Invoke-Step "start_postgresql" @(".\bin\cluster_ssh.py", "run", "--script", ".\bin\cluster_start_postgresql.sh", "--sudo-stdin") "start_postgresql.out" | Out-Null
Invoke-Step "start_hive" @(".\bin\cluster_ssh.py", "run", "--script", ".\bin\cluster_start_hive.sh") "start_hive.out" | Out-Null
Invoke-Step "start_realtime_services" @(".\bin\cluster_ssh.py", "run", "--script", ".\bin\cluster_start_realtime_services.sh", "--sudo-stdin") "start_realtime_services.out" | Out-Null

if ([string]::IsNullOrWhiteSpace($RemoteRunDir)) {
    $clusterOutput = Invoke-Step "cluster_restart_readiness" @(".\bin\cluster_ssh.py", "run", "--script", ".\bin\p15_cluster_restart_readiness.sh") "cluster_restart_readiness.out" -AllowFail
    $RemoteRunDir = ($clusterOutput | Select-String -Pattern '^P15_CLUSTER_RUN_DIR=' | Select-Object -Last 1).Line -replace '^P15_CLUSTER_RUN_DIR=', ''
}

if ([string]::IsNullOrWhiteSpace($RemoteRunDir)) {
    throw "Could not determine P15 remote run directory"
}

$remoteFiles = @(
    "p15_summary.md",
    "p15_status.tsv",
    "steps.tsv",
    "component_status.tsv",
    "table_counts.tsv",
    "realtime_restart_status.tsv",
    "node_snapshot.txt",
    "hdfs_finance_ls.out",
    "yarn_nodes.out",
    "yarn_running_apps.out",
    "beeline_finance_database.out",
    "kafka_quorum.out",
    "flink_running_jobs.out",
    "spark_show_tables.out",
    "kafka_topics.out"
)
$remotePaths = $remoteFiles | ForEach-Object { "$RemoteRunDir/$_" }
$downloadArgs = @(".\bin\cluster_ssh.py", "download", "--local-dir", $localRunDir) + $remotePaths
Invoke-Step "download_evidence" $downloadArgs "download_evidence.out" | Out-Null

$statusPath = Join-Path $localRunDir "p15_status.tsv"
$statusMap = @{}
Import-Csv -LiteralPath $statusPath -Delimiter "`t" | ForEach-Object {
    $statusMap[$_.metric] = $_.value
}
$overall = if ($statusMap["p15_status"] -eq "PASS") { "PASS" } else { "FAIL" }

$localSummary = @"
# P15 Local Restart Readiness Summary

- Remote run dir: ``$RemoteRunDir``
- Local run dir: ``$localRunDir``
- Required component status: ``$($statusMap["required_component_status"])``
- Realtime warning count: ``$($statusMap["realtime_warn_count"])``
- Overall status: ``$overall``

P15 validates service recovery after VM restart. Redis historical latest-state keys are warning-only because they can be volatile after restart.
"@
$localSummary | Set-Content -LiteralPath (Join-Path $localRunDir "p15_local_summary.md") -Encoding UTF8

Write-Host "P15_LOCAL_RUN_DIR=$localRunDir"
Write-Host "P15_REMOTE_RUN_DIR=$RemoteRunDir"
Write-Host "P15_STATUS=$overall"

if ($overall -ne "PASS") {
    exit 2
}
