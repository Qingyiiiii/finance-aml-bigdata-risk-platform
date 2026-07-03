# Purpose: P3-P4 本地离线数仓构建入口，顺序生成 DWD 明细和 DWS 风险指标。
# Boundary: 只读取 HI-Small accepted 本地输入，不代表 P5/P14 集群验收已经通过。
param(
    [string]$Config = "config/finance_bigdata.local.yaml"
)

$ErrorActionPreference = "Stop"
$env:PYTHONDONTWRITEBYTECODE = "1"

function Invoke-FinanceStep {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [string[]]$ExtraArgs = @()
    )

    Write-Host "===== $Name ====="
    python -B $ScriptPath --config $Config @ExtraArgs
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE"
    }
}

Set-Location (Split-Path -Parent $PSScriptRoot)

Invoke-FinanceStep -Name "P3 DWD build" -ScriptPath "src/03_finance_dwd_build.py"

$latestP3 = Get-ChildItem -LiteralPath "data/finance_bigdata/runs" -Directory |
    Where-Object { $_.Name -like "p3_dwd_build_*" } |
    Sort-Object Name |
    Select-Object -Last 1

if ($null -eq $latestP3) {
    throw "No p3_dwd_build_* run directory found after P3"
}

Invoke-FinanceStep -Name "P4 DWS risk KPI" -ScriptPath "src/04_finance_dws_risk_kpi.py" -ExtraArgs @("--dwd-run-dir", $latestP3.FullName)

Write-Host "FINANCE_P3_P4_STATUS=PASS"
