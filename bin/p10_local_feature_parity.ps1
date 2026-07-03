# Purpose: P10 本地编排入口，上传脚本、远程构建 warehouse-derived features 并下载证据。
# Boundary: P10 验证特征一致性，不训练新模型，也不替代 P14。
param(
    [string]$P9RunDir = "data\finance_bigdata\runs\p9_model_baseline_20260609_231710",
    [string]$RemoteStageDir = "/home/common/tmp/finance_bigdata_project/stage/p10_input"
)

$ErrorActionPreference = "Stop"
$env:PYTHONDONTWRITEBYTECODE = "1"

if (-not $env:FINANCE_VM_PASSWORD) {
    throw "FINANCE_VM_PASSWORD is not set"
}

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$p9FeaturePath = Join-Path $root (Join-Path $P9RunDir "feature_dataset.parquet")
if (-not (Test-Path -LiteralPath $p9FeaturePath)) {
    throw "P9 feature dataset not found: $p9FeaturePath"
}

Write-Host "===== P10 upload P9 feature dataset ====="
python -B .\bin\cluster_ssh.py upload --remote-dir $RemoteStageDir $p9FeaturePath
if ($LASTEXITCODE -ne 0) {
    throw "P10 upload failed with exit code $LASTEXITCODE"
}

Write-Host "===== P10 cluster feature parity ====="
$clusterOutput = python -B .\bin\cluster_ssh.py run --script .\bin\p10_cluster_feature_parity.sh 2>&1
$clusterExitCode = $LASTEXITCODE
$clusterOutput | Out-Host

$remoteRunDir = ($clusterOutput | Select-String -Pattern '^P10_CLUSTER_RUN_DIR=' | Select-Object -Last 1).Line -replace '^P10_CLUSTER_RUN_DIR=', ''
if ([string]::IsNullOrWhiteSpace($remoteRunDir)) {
    throw "Could not determine P10 remote run directory"
}

$localRunName = Split-Path -Leaf $remoteRunDir
$localRunDir = Join-Path $root "data\finance_bigdata\runs\$localRunName"
New-Item -ItemType Directory -Force -Path $localRunDir | Out-Null

$remoteFiles = @(
    "p10_summary.md",
    "steps.tsv",
    "source_table_counts.tsv",
    "row_parity.tsv",
    "schema_parity.tsv",
    "required_field_scan.tsv",
    "leakage_field_scan.tsv",
    "sample_label_split_summary.tsv",
    "numeric_parity.tsv",
    "categorical_parity.tsv",
    "postcheck.tsv",
    "hdfs_stage_inventory.txt",
    "spark_sql.err",
    "yarn_running_apps_after.out"
)

$remotePaths = $remoteFiles | ForEach-Object { "$remoteRunDir/$_" }
Write-Host "===== P10 download evidence ====="
python -B .\bin\cluster_ssh.py download --local-dir $localRunDir @remotePaths
if ($LASTEXITCODE -ne 0) {
    throw "P10 evidence download failed with exit code $LASTEXITCODE"
}

$failPatterns = @(
    @{ file = "source_table_counts.tsv"; pattern = "`tFAIL$" },
    @{ file = "row_parity.tsv"; pattern = "`tFAIL`t" },
    @{ file = "numeric_parity.tsv"; pattern = "`tFAIL$" },
    @{ file = "categorical_parity.tsv"; pattern = "`tFAIL$" },
    @{ file = "required_field_scan.tsv"; pattern = "`tFAIL`t" },
    @{ file = "leakage_field_scan.tsv"; pattern = "`tFAIL`t" },
    @{ file = "postcheck.tsv"; pattern = "`tFAIL`t" }
)

$localEvidenceStatus = "PASS"
foreach ($item in $failPatterns) {
    $path = Join-Path $localRunDir $item.file
    if (-not (Test-Path -LiteralPath $path)) {
        $localEvidenceStatus = "FAIL"
        continue
    }
    if (Select-String -Path $path -Pattern $item.pattern -Quiet) {
        $localEvidenceStatus = "FAIL"
    }
}

$overall = if (($clusterExitCode -eq 0) -and ($localEvidenceStatus -eq "PASS")) { "PASS" } else { "FAIL" }

$localSummary = @"
# P10 Local Feature Parity Summary

- Remote run dir: ``$remoteRunDir``
- Local run dir: ``$localRunDir``
- P9 feature dataset: ``$p9FeaturePath``
- Local evidence status: ``$localEvidenceStatus``
- Cluster exit code: ``$clusterExitCode``
- Overall status: ``$overall``

P10 verifies that Iceberg warehouse tables can re-derive the P9 non-leakage feature contract. It does not train a new model and does not replace P9.
"@
$localSummary | Set-Content -LiteralPath (Join-Path $localRunDir "p10_local_summary.md") -Encoding UTF8

Write-Host "P10_LOCAL_RUN_DIR=$localRunDir"
Write-Host "P10_LOCAL_EVIDENCE_STATUS=$localEvidenceStatus"
Write-Host "P10_STATUS=$overall"

if ($overall -ne "PASS") {
    exit 2
}
