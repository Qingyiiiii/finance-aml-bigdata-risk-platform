# Purpose: P7 本地编排入口，远程执行 readiness snapshot 并下载证据镜像。
# Boundary: P7 是 readiness 快照，不是 P14 master validation。
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

if ([string]::IsNullOrWhiteSpace($RemoteRunDir)) {
    $output = python -B .\bin\cluster_ssh.py run --script .\bin\p7_cluster_readiness_snapshot.sh
    $output | Tee-Object -Variable clusterOutput | Out-Host
    $RemoteRunDir = ($clusterOutput | Select-String -Pattern '^P7_CLUSTER_RUN_DIR=' | Select-Object -Last 1).Line -replace '^P7_CLUSTER_RUN_DIR=', ''
}

if ([string]::IsNullOrWhiteSpace($RemoteRunDir)) {
    throw "Could not determine P7 remote run directory"
}

if ([string]::IsNullOrWhiteSpace($LocalRunName)) {
    $LocalRunName = Split-Path -Leaf $RemoteRunDir
}

$localRunDir = Join-Path $root "data\finance_bigdata\runs\$LocalRunName"
New-Item -ItemType Directory -Force -Path $localRunDir | Out-Null

$remoteFiles = @(
    "p7_summary.md",
    "steps.tsv",
    "component_status.tsv",
    "namespace_snapshot.tsv",
    "table_counts.tsv",
    "realtime_snapshot.tsv",
    "node_snapshot.txt",
    "spark_show_tables.out",
    "kafka_topics.out",
    "kafka_quorum.out",
    "kafka_risk_topic_sample.jsonl",
    "redis_risk_key_sample.json",
    "flink_running_jobs.out",
    "yarn_running_apps.out"
)

$remotePaths = $remoteFiles | ForEach-Object { "$RemoteRunDir/$_" }
python -B .\bin\cluster_ssh.py download --local-dir $localRunDir @remotePaths

$expectedEvidence = @(
    @{ phase = "P0"; run_dir = "p0_preflight_20260609_200713"; required = "summary.tsv" },
    @{ phase = "P1"; run_dir = "p1_profile_20260609_200713"; required = "profile_metrics.tsv" },
    @{ phase = "P2"; run_dir = "p2_ods_sample_20260609_200745"; required = "ods_validation_summary.tsv" },
    @{ phase = "P3"; run_dir = "p3_dwd_build_20260609_203822"; required = "dwd_summary.tsv" },
    @{ phase = "P4"; run_dir = "p4_dws_risk_kpi_20260609_204441"; required = "dws_summary.tsv" },
    @{ phase = "P5"; run_dir = "p5_hive_iceberg_publish_20260609_064034"; required = "count_validation.tsv" },
    @{ phase = "P6"; run_dir = "p6_realtime_demo_20260609_070436"; required = "redis_set_summary.tsv" }
)

$snapshotPath = Join-Path $localRunDir "local_evidence_snapshot.tsv"
"phase`tlocal_run_dir`trequired_file`tstatus`tdetail" | Set-Content -LiteralPath $snapshotPath -Encoding UTF8
$allLocalPass = $true
foreach ($item in $expectedEvidence) {
    $dirPath = Join-Path $root "data\finance_bigdata\runs\$($item.run_dir)"
    $requiredPath = Join-Path $dirPath $item.required
    if ((Test-Path -LiteralPath $dirPath) -and (Test-Path -LiteralPath $requiredPath)) {
        $status = "PASS"
        $detail = $requiredPath
    } else {
        $status = "FAIL"
        $detail = "missing directory or required file"
        $allLocalPass = $false
    }
    "$($item.phase)`t$($item.run_dir)`t$($item.required)`t$status`t$detail" | Add-Content -LiteralPath $snapshotPath -Encoding UTF8
}

$componentFail = Select-String -Path (Join-Path $localRunDir "component_status.tsv") -Pattern "`tFAIL`t" -Quiet
$namespaceFail = Select-String -Path (Join-Path $localRunDir "namespace_snapshot.tsv") -Pattern "`tFAIL`t" -Quiet
$tableFail = Select-String -Path (Join-Path $localRunDir "table_counts.tsv") -Pattern "`tFAIL$" -Quiet
$realtimeFail = Select-String -Path (Join-Path $localRunDir "realtime_snapshot.tsv") -Pattern "`tFAIL`t" -Quiet

$overall = if ($allLocalPass -and -not $componentFail -and -not $namespaceFail -and -not $tableFail -and -not $realtimeFail) { "PASS" } else { "FAIL" }

$localSummary = @"
# P7 Local Readiness Snapshot

- Remote run dir: ``$RemoteRunDir``
- Local run dir: ``$localRunDir``
- Local evidence status: ``$(if ($allLocalPass) { "PASS" } else { "FAIL" })``
- Overall status: ``$overall``

P7 is a readiness snapshot, not P14 master validation.
"@
$localSummary | Set-Content -LiteralPath (Join-Path $localRunDir "p7_local_summary.md") -Encoding UTF8

Write-Host "P7_LOCAL_RUN_DIR=$localRunDir"
Write-Host "P7_LOCAL_EVIDENCE_STATUS=$(if ($allLocalPass) { 'PASS' } else { 'FAIL' })"
Write-Host "P7_STATUS=$overall"

if ($overall -ne "PASS") {
    exit 2
}
