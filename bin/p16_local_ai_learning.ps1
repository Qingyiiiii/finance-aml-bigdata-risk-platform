# Purpose: P16 AI 学习增强入口，生成模型解释和异常检测学习报告。
# Boundary: P16 不替代 P9 baseline，也不替代 P14 总验收。
param(
    [string]$P9RunDir = "data\finance_bigdata\runs\p9_model_baseline_20260609_231710",
    [int]$SampleSize = 50000
)

$ErrorActionPreference = "Stop"
$env:PYTHONDONTWRITEBYTECODE = "1"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

python -B .\analysis\p16_model_explainability.py --p9-run-dir $P9RunDir --sample-size $SampleSize
if ($LASTEXITCODE -ne 0) {
    throw "P16 AI learning enhancement failed with exit code $LASTEXITCODE"
}
