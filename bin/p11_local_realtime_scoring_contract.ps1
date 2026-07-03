# Purpose: P11 本地编排入口，生成评分契约样本、上传集群执行并下载证据。
# Boundary: P11 验证实时评分输入/输出契约，不表示生产模型上线。
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

$sampleDir = Join-Path $root "data\finance_bigdata\realtime_samples"
New-Item -ItemType Directory -Force -Path $sampleDir | Out-Null
$samplePath = Join-Path $sampleDir "finance_scoring_contract_sample_$Rows.jsonl"
$sampleSummary = Join-Path $sampleDir "p11_scoring_contract_sample_${Rows}_summary.tsv"

Write-Host "===== P11 make scoring contract sample ====="
python -B .\streaming\finance_make_scoring_contract_sample.py `
    --features $p9FeaturePath `
    --transactions $p3TransactionPath `
    --output $samplePath `
    --summary $sampleSummary `
    --rows $Rows
if ($LASTEXITCODE -ne 0) {
    throw "P11 sample generation failed with exit code $LASTEXITCODE"
}

Write-Host "===== P11 upload scripts and contract ====="
python -B .\bin\cluster_ssh.py upload --remote-dir "$RemoteRoot/streaming" `
    .\streaming\finance_scoring_contract_flink.sql `
    .\streaming\finance_collect_contract_to_redis.py
if ($LASTEXITCODE -ne 0) {
    throw "P11 streaming script upload failed with exit code $LASTEXITCODE"
}
python -B .\bin\cluster_ssh.py upload --remote-dir "$RemoteRoot/contracts" `
    .\contracts\p11_realtime_scoring_contract.md
if ($LASTEXITCODE -ne 0) {
    throw "P11 contract upload failed with exit code $LASTEXITCODE"
}
python -B .\bin\cluster_ssh.py upload --remote-dir "$RemoteRoot/stage/p11_input" $samplePath
if ($LASTEXITCODE -ne 0) {
    throw "P11 sample upload failed with exit code $LASTEXITCODE"
}

Write-Host "===== P11 cluster realtime scoring contract ====="
$clusterOutput = python -B .\bin\cluster_ssh.py run --script .\bin\p11_cluster_realtime_scoring_contract.sh 2>&1
$clusterExitCode = $LASTEXITCODE
$clusterOutput | Out-Host

$remoteRunDir = ($clusterOutput | Select-String -Pattern '^P11_RUN_DIR=' | Select-Object -Last 1).Line -replace '^P11_RUN_DIR=', ''
if ([string]::IsNullOrWhiteSpace($remoteRunDir)) {
    $remoteRunDir = ($clusterOutput | Select-String -Pattern '^P11_CLUSTER_RUN_DIR=' | Select-Object -Last 1).Line -replace '^P11_CLUSTER_RUN_DIR=', ''
}
if ([string]::IsNullOrWhiteSpace($remoteRunDir)) {
    throw "Could not determine P11 remote run directory"
}

$localRunName = Split-Path -Leaf $remoteRunDir
$localRunDir = Join-Path $root "data\finance_bigdata\runs\$localRunName"
New-Item -ItemType Directory -Force -Path $localRunDir | Out-Null

$remoteFiles = @(
    "p11_summary.md",
    "p11_realtime_scoring_contract.md",
    "steps.tsv",
    "redis_contract_summary.tsv",
    "risk_events_sample.jsonl",
    "risk_events_invalid.jsonl",
    "risk_events_raw.jsonl",
    "risk_consumer.err",
    "input_topic_describe.txt",
    "risk_topic_describe.txt",
    "flink_scoring_contract.sql",
    "flink_sql_submit.out",
    "flink_jobs_before.txt",
    "flink_jobs_after_submit.txt",
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
Write-Host "===== P11 download evidence ====="
python -B .\bin\cluster_ssh.py download --local-dir $localRunDir @remotePaths
if ($LASTEXITCODE -ne 0) {
    throw "P11 evidence download failed with exit code $LASTEXITCODE"
}

Copy-Item -LiteralPath $sampleSummary -Destination (Join-Path $localRunDir "local_sample_summary.tsv") -Force

$summaryPath = Join-Path $localRunDir "redis_contract_summary.tsv"
$postcheckPath = Join-Path $localRunDir "postcheck.tsv"
$rawEvents = 0
$validEvents = 0
$invalidEvents = 1
$redisKeys = 0
Import-Csv -LiteralPath $summaryPath -Delimiter "`t" | ForEach-Object {
    if ($_.metric -eq "raw_event_count") { $rawEvents = [int]$_.value }
    if ($_.metric -eq "schema_valid_event_count") { $validEvents = [int]$_.value }
    if ($_.metric -eq "schema_invalid_event_count") { $invalidEvents = [int]$_.value }
    if ($_.metric -eq "redis_keys_written") { $redisKeys = [int]$_.value }
}
$postcheckFail = Select-String -Path $postcheckPath -Pattern "`tFAIL`t" -Quiet
$localEvidenceStatus = if (($rawEvents -gt 0) -and ($validEvents -gt 0) -and ($invalidEvents -eq 0) -and ($redisKeys -gt 0) -and (-not $postcheckFail)) { "PASS" } else { "FAIL" }
$overall = if (($clusterExitCode -eq 0) -and ($localEvidenceStatus -eq "PASS")) { "PASS" } else { "FAIL" }

$localSummary = @"
# P11 Local Realtime Scoring Contract Summary

- Remote run dir: ``$remoteRunDir``
- Local run dir: ``$localRunDir``
- Local sample summary: ``$sampleSummary``
- Raw risk events: ``$rawEvents``
- Schema valid events: ``$validEvents``
- Schema invalid events: ``$invalidEvents``
- Redis keys written: ``$redisKeys``
- Cluster exit code: ``$clusterExitCode``
- Local evidence status: ``$localEvidenceStatus``
- Overall status: ``$overall``

P11 verifies a realtime scoring contract and Kafka/Flink/Redis loop. It does not train a new model and does not replace P9.
"@
$localSummary | Set-Content -LiteralPath (Join-Path $localRunDir "p11_local_summary.md") -Encoding UTF8

Write-Host "P11_LOCAL_RUN_DIR=$localRunDir"
Write-Host "P11_LOCAL_EVIDENCE_STATUS=$localEvidenceStatus"
Write-Host "P11_STATUS=$overall"

if ($overall -ne "PASS") {
    exit 2
}
