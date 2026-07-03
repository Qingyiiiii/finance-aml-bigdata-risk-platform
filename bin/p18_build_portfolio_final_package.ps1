# Purpose: P18 最终作品集包生成入口，负责轻量导航包和演示清单。
# Boundary: 最终包不得包含原始数据、大 CSV、Parquet、凭据或外部项目证据。
param(
    [string]$OutputRoot = "data\finance_bigdata\portfolio_packages"
)

$ErrorActionPreference = "Stop"
$env:PYTHONDONTWRITEBYTECODE = "1"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Join-ProjectPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $root $Path)
}

function Read-Tsv {
    param([string]$Path)
    return Import-Csv -LiteralPath (Join-ProjectPath $Path) -Delimiter "`t"
}

function Read-Kv {
    param([string]$Path)
    $map = @{}
    Read-Tsv $Path | ForEach-Object { $map[[string]$_.metric] = [string]$_.value }
    return $map
}

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    $full = Join-ProjectPath $Path
    $parent = Split-Path -Parent $full
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($full, $Text, $utf8NoBom)
}

function Copy-SmallFile {
    param([string]$Source, [string]$DestinationDir)
    $sourcePath = Join-ProjectPath $Source
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Missing source file: $Source"
    }
    if ((Get-Item -LiteralPath $sourcePath).Length -gt 5MB) {
        throw "Refuse to copy large file: $Source"
    }
    New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $DestinationDir (Split-Path -Leaf $sourcePath)) -Force
}

function Count-BadPackageFiles {
    param([string]$Path)
    $bad = Get-ChildItem -LiteralPath $Path -Recurse -File | Where-Object {
        $_.Length -gt 5MB -or
        $_.Name -match "^(HI|LI)-.*\.csv$" -or
        $_.Extension -eq ".parquet"
    }
    return @($bad).Count
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$packageName = "p18_portfolio_final_package_$stamp"
$packageDir = Join-ProjectPath (Join-Path $OutputRoot $packageName)
$materialsDir = Join-Path $packageDir "copied_materials"
New-Item -ItemType Directory -Force -Path $materialsDir | Out-Null

$p14 = Read-Kv "data\finance_bigdata\runs\p14_master_validation_20260611_184955\summary.tsv"
$p15 = Read-Kv "data\finance_bigdata\runs\p15_restart_readiness_20260613_211415\p15_status.tsv"
$p16 = @{}
Read-Tsv "data\finance_bigdata\runs\p16_model_explainability_20260613_211955\p16_status.tsv" | ForEach-Object { $p16[[string]$_.metric] = [string]$_.value }
$p17RunDir = (Get-ChildItem -LiteralPath (Join-ProjectPath "data\finance_bigdata\runs") -Directory -Filter "p17_data_quality_check_*" | Sort-Object Name | Select-Object -Last 1).FullName
$p17 = Read-Kv (Join-Path $p17RunDir "p17_status.tsv")

$copyList = @(
    "README.md",
    "项目文档索引.md",
    "quality\finance_quality_rules.md",
    "data\finance_bigdata\runs\p14_master_validation_20260611_184955\p14_summary.md",
    "data\finance_bigdata\runs\p15_restart_readiness_20260613_211415\p15_summary.md",
    "data\finance_bigdata\runs\p16_model_explainability_20260613_211955\p16_summary.md",
    "data\finance_bigdata\runs\p16_model_explainability_20260613_211955\model_explainability_report.md",
    "data\finance_bigdata\runs\p16_model_explainability_20260613_211955\anomaly_detection_report.md",
    (Join-Path $p17RunDir "p17_summary.md"),
    (Join-Path $p17RunDir "quality_check_results.tsv"),
    "data\finance_bigdata\bi_packages\p13_bi_dashboard_package_20260611_172808\dashboard_index.md",
    "data\finance_bigdata\bi_packages\p13_bi_dashboard_package_20260611_172808\dashboard_preview.html",
    "data\finance_bigdata\bi_packages\p13_bi_dashboard_package_20260611_172808\dashboard_metric_catalog.md",
    "data\finance_bigdata\bi_packages\p13_bi_dashboard_package_20260611_172808\dashboard_sql_reference.md"
)
foreach ($file in $copyList) {
    $targetDir = Join-Path $materialsDir ((Split-Path -Parent $file) -replace "[:\\\/]", "_")
    Copy-SmallFile $file $targetDir
}

$portfolioEntry = @"
# Finance Big Data Portfolio Entry


- P14 总验收：``data/finance_bigdata/runs/p14_master_validation_20260611_184955``
- P15 重启恢复：``data/finance_bigdata/runs/p15_restart_readiness_20260613_211415``
- P16 AI 解释增强：``data/finance_bigdata/runs/p16_model_explainability_20260613_211955``
- P17 数据质量规则：``quality/finance_quality_rules.md``
- P18 最终作品集包：``$packageDir``


1. 先讲项目定位：展示型金融大数据项目，不是生产系统。
2. 再讲链路：P0-P4 数据层，P5 湖仓发布，P6/P11 实时链路，P12 查询层，P13 BI，P16 AI 解释。
3. 展示 P14：证明 P0-P13 总证据链 PASS。
4. 展示 P15：证明虚拟机重启后服务能恢复。
5. 展示 P16：解释模型特征、类别不平衡、PR-AUC 和异常检测实验。
6. 展示 P17：说明数据质量与监控规则。


- BI 预览：``data/finance_bigdata/bi_packages/p13_bi_dashboard_package_20260611_172808/dashboard_preview.html``
- 模型解释：``data/finance_bigdata/runs/p16_model_explainability_20260613_211955/model_explainability_report.md``
- 数据质量规则：``quality/finance_quality_rules.md``


本入口不复制原始数据，不包含大 CSV 或 Parquet 明细，不处理 Medium/Large，不复用外部项目证据。
"@
Write-Utf8 "portfolio\金融大数据项目作品集入口.md" $portfolioEntry
Write-Utf8 (Join-Path $packageDir "portfolio_index.md") $portfolioEntry

$story = @"
# Portfolio Story

This package is the final lightweight portfolio entry for the finance big-data project. It links the accepted P14 master validation, P15 restart readiness, P16 AI explanation enhancement, P17 data quality rules and P13 BI materials.


- P14 status: ``$($p14["p14_status"])``
- P15 status: ``$($p15["p15_status"])``
- P16 status: ``$($p16["p16_status"])``
- P17 status: ``$($p17["p17_status"])``


- End-to-end architecture and phase evidence.
- BI dashboard preview.
- Feature importance and AI metric interpretation.
- Restart readiness and data quality checks.
"@
Write-Utf8 (Join-Path $packageDir "portfolio_story.md") $story

$checklist = @"
# Final Demo Checklist

| Step | File | Purpose |
| --- | --- | --- |
| 1 | ``portfolio_index.md`` | final navigation |
| 2 | ``copied_materials/data_finance_bigdata_bi_packages_p13_bi_dashboard_package_20260611_172808/dashboard_preview.html`` | BI preview |
| 3 | ``copied_materials/data_finance_bigdata_runs_p16_model_explainability_20260613_211955/model_explainability_report.md`` | AI explanation |
| 4 | ``copied_materials/quality/finance_quality_rules.md`` | data quality rules |

Use this package as a navigation layer. The authoritative evidence remains in ``data/finance_bigdata``.
"@
Write-Utf8 (Join-Path $packageDir "final_demo_checklist.md") $checklist

$files = Get-ChildItem -LiteralPath $packageDir -Recurse -File
$badCount = Count-BadPackageFiles $packageDir
$required = @("portfolio_index.md", "portfolio_story.md", "final_demo_checklist.md")
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $packageDir $_)) }).Count
$status = if ($badCount -eq 0 -and $missing -eq 0 -and $p14["p14_status"] -eq "PASS" -and $p15["p15_status"] -eq "PASS" -and $p16["p16_status"] -eq "PASS" -and $p17["p17_status"] -eq "PASS") { "PASS" } else { "FAIL" }
$finalFileCount = $files.Count + 2

$statusText = @"
metric	value	status
package_name	$packageName	PASS
package_dir	$packageDir	PASS
p14_status	$($p14["p14_status"])	$(if ($p14["p14_status"] -eq "PASS") { "PASS" } else { "FAIL" })
p15_status	$($p15["p15_status"])	$(if ($p15["p15_status"] -eq "PASS") { "PASS" } else { "FAIL" })
p16_status	$($p16["p16_status"])	$(if ($p16["p16_status"] -eq "PASS") { "PASS" } else { "FAIL" })
p17_status	$($p17["p17_status"])	$(if ($p17["p17_status"] -eq "PASS") { "PASS" } else { "FAIL" })
package_file_count	$finalFileCount	PASS
bad_raw_or_parquet_files	$badCount	$(if ($badCount -eq 0) { "PASS" } else { "FAIL" })
missing_required_files	$missing	$(if ($missing -eq 0) { "PASS" } else { "FAIL" })
p18_status	$status	$status
"@
Write-Utf8 (Join-Path $packageDir "p18_status.tsv") $statusText

$summary = @"
# P18 Portfolio Final Package Summary

- Package name: ``$packageName``
- Package dir: ``$packageDir``
- P14 status: ``$($p14["p14_status"])``
- P15 status: ``$($p15["p15_status"])``
- P16 status: ``$($p16["p16_status"])``
- P17 status: ``$($p17["p17_status"])``
- Package file count: ``$finalFileCount``
- Bad raw or parquet files: ``$badCount``
- Status: ``$status``


P18 is a lightweight portfolio navigation package. It does not copy raw datasets, large CSV files, Parquet detail outputs, credentials, or external project evidence.
"@
Write-Utf8 (Join-Path $packageDir "p18_summary.md") $summary

Write-Host "P18_PACKAGE_DIR=$packageDir"
Write-Host "P18_STATUS=$status"
if ($status -ne "PASS") {
    exit 2
}
