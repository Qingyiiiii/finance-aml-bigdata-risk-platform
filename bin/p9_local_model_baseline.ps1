# Purpose: P9 本地 AI baseline 编排入口，依次执行 EDA、特征构建和基线模型。
# Boundary: P9 是学习型 baseline，不是生产 AML 模型，也不替代 P14 总验收。
param(
    [string]$RunDir = ""
)

$ErrorActionPreference = "Stop"
$env:PYTHONDONTWRITEBYTECODE = "1"

Set-Location (Split-Path -Parent $PSScriptRoot)

if ([string]::IsNullOrWhiteSpace($RunDir)) {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $RunDir = "data/finance_bigdata/runs/p9_model_baseline_$stamp"
}

New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

function Invoke-P9Step {
    param(
        [string]$Name,
        [string]$Script,
        [string[]]$ExtraArgs = @()
    )
    Write-Host "===== $Name ====="
    python -B $Script --run-dir $RunDir @ExtraArgs
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE"
    }
}

"step`tstatus`tdetail" | Set-Content -LiteralPath (Join-Path $RunDir "steps.tsv") -Encoding UTF8

Invoke-P9Step -Name "P9 label EDA" -Script "analysis/p9_label_eda.py"
"label_eda`tPASS`tlabel_distribution.tsv, eda_metrics.tsv" | Add-Content -LiteralPath (Join-Path $RunDir "steps.tsv") -Encoding UTF8

Invoke-P9Step -Name "P9 feature build" -Script "analysis/p9_feature_build.py"
"feature_build`tPASS`tfeature_dataset.parquet" | Add-Content -LiteralPath (Join-Path $RunDir "steps.tsv") -Encoding UTF8

Invoke-P9Step -Name "P9 baseline model" -Script "analysis/p9_baseline_model.py"
"baseline_model`tPASS`tbaseline_metrics.tsv, model_card.md" | Add-Content -LiteralPath (Join-Path $RunDir "steps.tsv") -Encoding UTF8

Write-Host "P9_RUN_DIR=$RunDir"
Write-Host "P9_STATUS=PASS"
