# Purpose: P0-P2 本地 smoke 入口，只验证原始文件、profile 和 ODS 样本。
# Boundary: 不启动集群，不处理 Medium/Large，不写入外部项目目录。
param(
    [string]$Config = "config/finance_bigdata.local.yaml"
)

$ErrorActionPreference = "Stop"
$env:PYTHONDONTWRITEBYTECODE = "1"

function Invoke-FinanceStep {
    param(
        [string]$Name,
        [string]$ScriptPath
    )

    Write-Host "===== $Name ====="
    python -B $ScriptPath --config $Config
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE"
    }
}

Set-Location (Split-Path -Parent $PSScriptRoot)

Invoke-FinanceStep -Name "P0 preflight" -ScriptPath "src/00_finance_preflight.py"
Invoke-FinanceStep -Name "P1 profile" -ScriptPath "src/01_finance_profile.py"
Invoke-FinanceStep -Name "P2 ODS sample" -ScriptPath "src/02_finance_ods_sample.py"

Write-Host "FINANCE_P0_P2_STATUS=PASS"
