# P11v2 local orchestrator: create sample, upload scripts, run cluster state landing, download evidence.
param(
    [string]$P9RunDir = "data\finance_bigdata\runs\p9_model_baseline_20260609_231710",
    [string]$P3RunDir = "data\finance_bigdata\runs\p3_dwd_build_20260609_203822",
    [int]$Rows = 10000,
    [string]$RemoteRoot = "/home/common/tmp/finance_bigdata_project"
)

$ErrorActionPreference = "Stop"
$env:PYTHONDONTWRITEBYTECODE = "1"

if (-not $env:FINANCE_VM_PASSWORD) {
    throw "FINANCE_VM_PASSWORD is not set"
}

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$p9FeaturePath = Join-Path $root (Join-Path $P9RunDir "feature_dataset.parquet")
$p3TransactionPath = Join-Path $root (Join-Path $P3RunDir "dwd_finance_transactions.parquet")
if (-not (Test-Path -LiteralPath $p9FeaturePath)) {
    throw "P9 feature dataset not found: $p9FeaturePath"
}
if (-not (Test-Path -LiteralPath $p3TransactionPath)) {
    throw "P3 transaction parquet not found: $p3TransactionPath"
}

$sampleDir = Join-Path $root "data\finance_bigdata_v2\realtime_samples"
$runsDir = Join-Path $root "data\finance_bigdata_v2\runs"
New-Item -ItemType Directory -Force -Path $sampleDir, $runsDir | Out-Null

$samplePath = Join-Path $sampleDir "finance_p11v2_state_sample_$Rows.jsonl"
$sampleSummary = Join-Path $sampleDir "p11v2_state_sample_${Rows}_summary.tsv"

function Invoke-CheckedStep {
    param(
        [string]$Name,
        [string[]]$Arguments,
        [switch]$AllowFail
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
    if (($exitCode -ne 0) -and (-not $AllowFail)) {
        throw "$Name failed with exit code $exitCode"
    }
    return @{ ExitCode = $exitCode; Output = $output }
}

Write-Host "===== P11v2 make realtime state sample ====="
python -B .\streaming\finance_make_p11v2_state_sample.py `
    --features $p9FeaturePath `
    --transactions $p3TransactionPath `
    --output $samplePath `
    --summary $sampleSummary `
    --rows $Rows
if ($LASTEXITCODE -ne 0) {
    throw "P11v2 sample generation failed with exit code $LASTEXITCODE"
}

Write-Host "===== P11v2 upload scripts and contract ====="
python -B .\bin\cluster_ssh.py upload --remote-dir "$RemoteRoot/streaming" `
    .\streaming\finance_p11v2_state_flink.sql `
    .\streaming\finance_collect_p11v2_state.py
if ($LASTEXITCODE -ne 0) {
    throw "P11v2 streaming upload failed with exit code $LASTEXITCODE"
}

python -B .\bin\cluster_ssh.py upload --remote-dir "$RemoteRoot/contracts" `
    .\contracts\p11v2_realtime_state_contract.md
if ($LASTEXITCODE -ne 0) {
    throw "P11v2 contract upload failed with exit code $LASTEXITCODE"
}

python -B .\bin\cluster_ssh.py upload --remote-dir "$RemoteRoot/stage/p11v2_input" $samplePath
if ($LASTEXITCODE -ne 0) {
    throw "P11v2 sample upload failed with exit code $LASTEXITCODE"
}

Invoke-CheckedStep "P11v2 start hdfs yarn" @(".\bin\cluster_ssh.py", "run", "--script", ".\bin\cluster_start_hdfs_yarn.sh") | Out-Null
Invoke-CheckedStep "P11v2 start realtime services" @(".\bin\cluster_ssh.py", "run", "--script", ".\bin\cluster_start_realtime_services.sh", "--sudo-stdin") | Out-Null

Write-Host "===== P11v2 cluster realtime state ====="
$oldErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $rawClusterOutput = & python -B .\bin\cluster_ssh.py run --script .\bin\p11v2_cluster_realtime_state.sh 2>&1
    $clusterExitCode = $LASTEXITCODE
    $clusterOutput = $rawClusterOutput | ForEach-Object { $_.ToString() }
}
finally {
    $ErrorActionPreference = $oldErrorActionPreference
}
$clusterOutput | Out-Host

$remoteRunDir = ($clusterOutput | Select-String -Pattern '^P11V2_RUN_DIR=' | Select-Object -Last 1).Line -replace '^P11V2_RUN_DIR=', ''
if ([string]::IsNullOrWhiteSpace($remoteRunDir)) {
    throw "Could not determine P11v2 remote run directory"
}

$localRunName = Split-Path -Leaf $remoteRunDir
$localRunDir = Join-Path $runsDir $localRunName
New-Item -ItemType Directory -Force -Path $localRunDir | Out-Null

$remoteFiles = @(
    "p11v2_summary.md",
    "p11v2_realtime_state_contract.md",
    "p11v2_steps.tsv",
    "p11v2_state_summary.tsv",
    "risk_events_sample.jsonl",
    "risk_events_invalid.jsonl",
    "risk_events_raw.jsonl",
    "risk_consumer.err",
    "hbase_readback_sample.tsv",
    "hbase_puts.hbase",
    "hbase_put.out",
    "hbase_put.err",
    "hbase_readback.hbase",
    "hbase_readback_raw.out",
    "hbase_readback.err",
    "hbase_status_before.txt",
    "hbase_status_after.txt",
    "hbase_process_snapshot.txt",
    "hbase_start.out",
    "hdfs_safemode.out",
    "input_topic_describe.txt",
    "risk_topic_describe.txt",
    "flink_p11v2_state.sql",
    "flink_sql_submit.out",
    "flink_jobs_before.txt",
    "flink_jobs_after_submit.txt",
    "flink_job_ids_to_cancel.txt",
    "flink_jobs_after_cancel.txt",
    "flink_cancel.out",
    "postcheck.tsv",
    "yarn_running_apps_after.out",
    "replay_count.txt",
    "producer_status.txt",
    "kafka_quorum.out",
    "redis_ping.out"
)
$remotePaths = $remoteFiles | ForEach-Object { "$remoteRunDir/$_" }

Write-Host "===== P11v2 download evidence ====="
python -B .\bin\cluster_ssh.py download --local-dir $localRunDir @remotePaths
if ($LASTEXITCODE -ne 0) {
    throw "P11v2 evidence download failed with exit code $LASTEXITCODE"
}

Copy-Item -LiteralPath $sampleSummary -Destination (Join-Path $localRunDir "local_sample_summary.tsv") -Force

$summaryPath = Join-Path $localRunDir "p11v2_state_summary.tsv"
$postcheckPath = Join-Path $localRunDir "postcheck.tsv"
$rawEvents = 0
$validEvents = 0
$invalidEvents = 1
$redisKeys = 0
$hbaseRows = 0
$consistencyFails = 1

Import-Csv -LiteralPath $summaryPath -Delimiter "`t" | ForEach-Object {
    if ($_.metric -eq "raw_event_count") { $rawEvents = [int]$_.value }
    if ($_.metric -eq "schema_valid_event_count") { $validEvents = [int]$_.value }
    if ($_.metric -eq "schema_invalid_event_count") { $invalidEvents = [int]$_.value }
    if ($_.metric -eq "redis_keys_written") { $redisKeys = [int]$_.value }
    if ($_.metric -eq "hbase_rows_written") { $hbaseRows = [int]$_.value }
    if ($_.metric -eq "redis_hbase_consistency_fail_count") { $consistencyFails = [int]$_.value }
}

$postcheckFail = Select-String -Path $postcheckPath -Pattern "`tFAIL`t" -Quiet
$localEvidenceStatus = if (($rawEvents -gt 0) -and ($validEvents -gt 0) -and ($invalidEvents -eq 0) -and ($redisKeys -gt 0) -and ($hbaseRows -gt 0) -and ($consistencyFails -eq 0) -and (-not $postcheckFail)) { "PASS" } else { "FAIL" }
$overall = if (($clusterExitCode -eq 0) -and ($localEvidenceStatus -eq "PASS")) { "PASS" } else { "FAIL" }

$localSummary = @"
# P11v2 Local Realtime State Summary

- Remote run dir: ``$remoteRunDir``
- Local run dir: ``$localRunDir``
- Local sample summary: ``$sampleSummary``
- Raw risk events: ``$rawEvents``
- Schema valid events: ``$validEvents``
- Schema invalid events: ``$invalidEvents``
- Redis keys written: ``$redisKeys``
- HBase rows written: ``$hbaseRows``
- Redis/HBase consistency failures: ``$consistencyFails``
- Cluster exit code: ``$clusterExitCode``
- Local evidence status: ``$localEvidenceStatus``
- Overall status: ``$overall``

P11v2 verifies Kafka/Flink risk scoring plus Redis cache and HBase durable account risk state. It does not replace P14v2 validation.
"@
$localSummary | Set-Content -LiteralPath (Join-Path $localRunDir "p11v2_local_summary.md") -Encoding UTF8

Write-Host "P11V2_LOCAL_RUN_DIR=$localRunDir"
Write-Host "P11V2_LOCAL_EVIDENCE_STATUS=$localEvidenceStatus"
Write-Host "P11V2_STATUS=$overall"

if ($overall -ne "PASS") {
    exit 2
}
