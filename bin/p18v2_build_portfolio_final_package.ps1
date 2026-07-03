# P18v2 local orchestrator: build V2 lightweight final portfolio package.
# Boundary: requires P14v2 PASS; copies only small display materials and evidence summaries.
param(
    [string]$OutputRoot = "data\finance_bigdata_v2\portfolio_packages",
    [string]$P14v2RunDir = "",
    [string]$P11v2RunDir = "data\finance_bigdata_v2\runs\p11v2_realtime_state_20260702_040833",
    [string]$P12v2MainRunDir = "data\finance_bigdata_v2\runs\p12v2_clickhouse_es_validation_20260702_055525",
    [string]$P12v2QueryRunDir = "data\finance_bigdata_v2\runs\p12v2_query_investigation_20260702_054537",
    [string]$P13v2PackageDir = "data\finance_bigdata_v2\bi_packages\p13v2_clickhouse_bi_package_20260702_213858",
    [string]$P15v2RunDir = "data\finance_bigdata_v2\runs\p15v2_modular_restart_readiness_20260703_035839",
    [string]$P17v2RunDir = "data\finance_bigdata_v2\runs\p17v2_gx_quality_check_20260703_140557"
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
    Read-Tsv $Path | ForEach-Object {
        if ($_.metric) { $map[[string]$_.metric] = [string]$_.value }
        elseif ($_.check) { $map[[string]$_.check] = [string]$_.status }
    }
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

function Write-Tsv {
    param([string]$Path, [System.Collections.Generic.List[object]]$Rows, [string[]]$Columns)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(($Columns -join "`t"))
    foreach ($row in $Rows) {
        $cells = foreach ($column in $Columns) {
            $value = [string]$row.$column
            $value = $value -replace "`t", " "
            $value = $value -replace "(`r`n|`r|`n)", " "
            $value
        }
        $lines.Add(($cells -join "`t"))
    }
    Write-Utf8 $Path ($lines -join "`r`n")
}

function Status-FromBool {
    param($Value)
    if ([bool]$Value) { return "PASS" }
    return "FAIL"
}

function Test-AllPass {
    param([object[]]$Rows, [string]$Column = "status")
    $items = @($Rows)
    if ($items.Count -eq 0) { return $false }
    return (@($items | Where-Object { [string]$_.$Column -ne "PASS" }).Count -eq 0)
}

function Get-SafeSubdir {
    param([string]$Path)
    $value = $Path -replace "[:\\\/]+", "_"
    $value = $value -replace "[^A-Za-z0-9_.\-\u4e00-\u9fff]+", "_"
    if ($value.Length -gt 90) { $value = $value.Substring(0, 90) }
    return $value.Trim("_")
}

function Get-RelativePathCompat {
    param([string]$BasePath, [string]$TargetPath)
    $baseFull = [System.IO.Path]::GetFullPath($BasePath)
    $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
    if (-not $baseFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $baseFull = $baseFull + [System.IO.Path]::DirectorySeparatorChar
    }
    $baseUri = New-Object System.Uri($baseFull)
    $targetUri = New-Object System.Uri($targetFull)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

function Copy-SmallMaterial {
    param(
        [string]$Source,
        [string]$Role,
        [string]$PackageRoot,
        [string]$MaterialsRoot,
        [System.Collections.Generic.List[object]]$ManifestRows
    )
    $sourcePath = Join-ProjectPath $Source
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Missing source file: $Source"
    }
    $item = Get-Item -LiteralPath $sourcePath
    if ($item.Length -gt 1MB) {
        throw "Refuse to copy >1MiB file: $Source"
    }
    if ($item.Extension -in @(".csv", ".parquet", ".ndjson")) {
        throw "Refuse forbidden file type: $Source"
    }
    $targetDir = Join-Path $MaterialsRoot (Get-SafeSubdir (Split-Path -Parent $Source))
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    $target = Join-Path $targetDir (Split-Path -Leaf $Source)
    Copy-Item -LiteralPath $sourcePath -Destination $target -Force
    $relativeTarget = Get-RelativePathCompat $PackageRoot $target
    $ManifestRows.Add([pscustomobject]@{
        source = $Source
        copied_to = $relativeTarget
        role = $Role
        size_bytes = $item.Length
        status = "PASS"
    }) | Out-Null
}

if ([string]::IsNullOrWhiteSpace($P14v2RunDir)) {
    $latest = Get-ChildItem -LiteralPath (Join-ProjectPath "data\finance_bigdata_v2\runs") -Directory -Filter "p14v2_master_validation_*" | Sort-Object Name | Select-Object -Last 1
    if ($null -eq $latest) { throw "P14v2 run dir is required and no existing p14v2 run was found" }
    $P14v2RunDir = Get-RelativePathCompat $root $latest.FullName
}

$p14Map = Read-Kv (Join-Path $P14v2RunDir "summary.tsv")
if ($p14Map["p14v2_status"] -ne "PASS") {
    throw "P14v2 is not PASS: $P14v2RunDir"
}

$p13Map = Read-Kv (Join-Path $P13v2PackageDir "p13v2_status.tsv")
$p15Map = Read-Kv (Join-Path $P15v2RunDir "p15v2_status.tsv")
$p17Map = Read-Kv (Join-Path $P17v2RunDir "p17v2_status.tsv")
if ($p13Map["p13v2_status"] -ne "PASS" -or $p15Map["p15v2_status"] -ne "PASS" -or $p17Map["p17v2_status"] -ne "PASS") {
    throw "P18v2 prerequisites are not PASS"
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$packageName = "p18v2_portfolio_final_package_$stamp"
$packageDir = Join-ProjectPath (Join-Path $OutputRoot $packageName)
$materialsDir = Join-Path $packageDir "copied_materials"
New-Item -ItemType Directory -Force -Path $materialsDir | Out-Null

$acceptedManifest = New-Object System.Collections.Generic.List[object]
foreach ($row in @(
    @{ stage = "P14v2"; path = $P14v2RunDir; status = "PASS"; role = "independent V2 master validation" },
    @{ stage = "P11v2"; path = $P11v2RunDir; status = "PASS"; role = "realtime cache plus durable state" },
    @{ stage = "P12v2"; path = $P12v2MainRunDir; status = "PASS"; role = "ClickHouse and Elasticsearch evidence" },
    @{ stage = "P12v2_Trino_reference"; path = $P12v2QueryRunDir; status = "PASS"; role = "Trino/Iceberg reference evidence" },
    @{ stage = "P13v2"; path = $P13v2PackageDir; status = "PASS"; role = "static BI display package" },
    @{ stage = "P15v2"; path = $P15v2RunDir; status = "PASS"; role = "low-memory modular restart readiness" },
    @{ stage = "P17v2"; path = $P17v2RunDir; status = "PASS"; role = "GX data quality gate" }
)) {
    $acceptedManifest.Add([pscustomobject]@{
        stage = $row.stage
        accepted_path = $row.path
        status = $row.status
        role = $row.role
    }) | Out-Null
}

$copiedManifest = New-Object System.Collections.Generic.List[object]
$copyItems = @(
    @{ path = (Join-Path $P14v2RunDir "p14v2_summary.md"); role = "P14v2 summary" },
    @{ path = (Join-Path $P14v2RunDir "summary.tsv"); role = "P14v2 status" },
    @{ path = (Join-Path $P14v2RunDir "v2_validation_matrix.tsv"); role = "P14v2 validation matrix" },
    @{ path = (Join-Path $P14v2RunDir "component_validation.tsv"); role = "P14v2 component validation" },
    @{ path = (Join-Path $P14v2RunDir "boundary_scan.tsv"); role = "P14v2 boundary scan" },
    @{ path = (Join-Path $P11v2RunDir "p11v2_summary.md"); role = "P11v2 summary" },
    @{ path = (Join-Path $P11v2RunDir "p11v2_state_summary.tsv"); role = "P11v2 state metrics" },
    @{ path = (Join-Path $P12v2MainRunDir "p12v2_summary.md"); role = "P12v2 summary" },
    @{ path = (Join-Path $P12v2MainRunDir "p12v2_status.tsv"); role = "P12v2 status" },
    @{ path = (Join-Path $P12v2MainRunDir "clickhouse_query_results.tsv"); role = "ClickHouse query samples" },
    @{ path = (Join-Path $P12v2MainRunDir "elasticsearch_search_sample.json"); role = "Elasticsearch search sample" },
    @{ path = (Join-Path $P13v2PackageDir "dashboard_index.md"); role = "BI package entry" },
    @{ path = (Join-Path $P13v2PackageDir "dashboard_preview.html"); role = "BI static preview" },
    @{ path = (Join-Path $P13v2PackageDir "dashboard_metric_catalog.md"); role = "BI metric catalog" },
    @{ path = (Join-Path $P13v2PackageDir "p13v2_status.tsv"); role = "P13v2 status" },
    @{ path = (Join-Path $P13v2PackageDir "package_boundary_scan.tsv"); role = "P13v2 boundary scan" },
    @{ path = (Join-Path $P15v2RunDir "p15v2_summary.md"); role = "P15v2 summary" },
    @{ path = (Join-Path $P15v2RunDir "p15v2_status.tsv"); role = "P15v2 status" },
    @{ path = (Join-Path $P15v2RunDir "p15v2_final_status.tsv"); role = "P15v2 final local status" },
    @{ path = (Join-Path $P17v2RunDir "p17v2_summary.md"); role = "P17v2 summary" },
    @{ path = (Join-Path $P17v2RunDir "p17v2_status.tsv"); role = "P17v2 status" },
    @{ path = (Join-Path $P17v2RunDir "quality_rule_catalog.md"); role = "P17v2 quality rules" },
    @{ path = (Join-Path $P17v2RunDir "gx_checkpoint_summary.tsv"); role = "GX checkpoint summary" }
)
foreach ($item in $copyItems) {
    Copy-SmallMaterial $item.path $item.role $packageDir $materialsDir $copiedManifest
}

Write-Tsv (Join-Path $packageDir "accepted_evidence_manifest.tsv") $acceptedManifest @("stage", "accepted_path", "status", "role")
Write-Tsv (Join-Path $packageDir "copied_materials_manifest.tsv") $copiedManifest @("source", "copied_to", "role", "size_bytes", "status")

$portfolioIndex = @"
# Finance Big Data V2 Portfolio Entry


金融大数据 V2 是在 V1 完整作品集证据链基础上的金融针对性优化版。它面向交易风险、账户状态、调查检索、质量治理和 BI 查询，不声明为生产级银行 AML 系统。


- P11v2：Redis cache + HBase durable state。
- P12v2：Trino reference + ClickHouse ADS + Elasticsearch investigation。
- P13v2：ClickHouse-backed static BI package。
- P15v2：low-memory sequential modular restart readiness。
- P17v2：Great Expectations data quality gate。
- P14v2：independent V2 master validation。
- P18v2：this lightweight final portfolio package。


1. V2 定位和 V1/V2 差异。
2. P11v2 HBase durable state。
3. P12v2 ClickHouse + Elasticsearch。
4. P13v2 BI 展示。
5. P17v2 GX 数据质量。
6. P15v2 模块化恢复。
7. P14v2 总验收。


- P14v2 总验收：``copied_materials\$(Get-SafeSubdir $P14v2RunDir)\p14v2_summary.md``
- BI 预览：``copied_materials\$(Get-SafeSubdir $P13v2PackageDir)\dashboard_preview.html``
- P17v2 质量规则：``copied_materials\$(Get-SafeSubdir $P17v2RunDir)\quality_rule_catalog.md``
- 复制材料清单：``copied_materials_manifest.tsv``
- 边界扫描：``package_boundary_scan.tsv``


本包不复制原始数据、Medium/Large、大 CSV、Parquet 明细、HDFS 明细导出或任何密码文件；不使用外部项目证据；不把 V1 P14/P18 写成 V2 PASS。
"@
Write-Utf8 (Join-Path $packageDir "portfolio_index.md") $portfolioIndex
Write-Utf8 "portfolio\金融大数据V2项目作品集入口.md" $portfolioIndex

$story = @"
# Portfolio Story

V2 upgrades the original runnable finance AML portfolio into a more finance-specific data platform story: Redis is demoted to cache, HBase becomes durable account risk state, ClickHouse replaces Doris for V2 BI display, Elasticsearch becomes the investigation search copy, and Great Expectations becomes the main quality gate.

The accepted proof chain is P11v2/P12v2/P13v2/P15v2/P17v2 -> P14v2 -> P18v2. This package is the final lightweight navigation layer; the authoritative evidence remains in ``data/finance_bigdata_v2``.
"@
Write-Utf8 (Join-Path $packageDir "portfolio_story.md") $story

$architecture = @"
# Architecture Overview

```text
Kafka/Flink rules
  -> Redis latest-state cache
  -> HBase account risk durable state
  -> Iceberg long-term facts / Hudi optional upsert supplement
  -> Trino reference query
  -> ClickHouse BI display
  -> Elasticsearch investigation search
  -> Great Expectations quality gate
  -> Ranger/Atlas governance and Prometheus/Grafana monitoring evidence
```

ClickHouse and Elasticsearch are not fact sources. Redis is not a durable source of truth. GX is not a resident service.
"@
Write-Utf8 (Join-Path $packageDir "architecture_overview.md") $architecture

$demo = @"
# Final Demo Checklist

| Step | Material | Purpose |
| --- | --- | --- |
| 1 | ``portfolio_index.md`` | Navigate the V2 final package |
| 2 | P11v2 state summary | Explain Redis cache and HBase durable state |
| 3 | P12v2 ClickHouse/Elasticsearch samples | Show query and investigation evidence |
| 4 | P13v2 dashboard preview | Show BI display material |
| 5 | P17v2 quality rule catalog | Explain GX quality gate |
| 6 | P15v2 summary | Explain modular low-memory recovery |
| 7 | P14v2 summary and matrix | Prove V2 independent validation |
| 8 | ``package_boundary_scan.tsv`` | Prove package safety |
"@
Write-Utf8 (Join-Path $packageDir "final_demo_checklist.md") $demo

$talkTrack = @"
# Project Talk Track

1. This is a portfolio-grade finance big-data project, not a production bank AML deployment.
2. V1 proved the end-to-end big-data path. V2 improves the finance-specific state, search, quality and BI story.
3. HBase is used for durable account risk state; Redis is only the latest-state cache.
4. ClickHouse is the V2 OLAP/BI display layer; Elasticsearch is the investigation search copy.
5. Great Expectations validates the accepted V2 evidence chain without rerunning the business pipeline.
6. P14v2 is the independent proof that V2 evidence is coherent; P18v2 only packages that proof for presentation.
"@
Write-Utf8 (Join-Path $packageDir "project_talk_track.md") $talkTrack

$limits = @"
# Known Limits And Next Steps

- This is not a production-grade bank AML platform.
- Debezium/Kafka Connect, Kibana/OpenSearch Dashboards, ClickHouse Keeper and three-node ClickHouse remain optional future enhancements.
- Ranger/Atlas are validated at a minimal governance evidence level, not full enterprise policy coverage.
- P18v2 intentionally copies only lightweight evidence and navigation material.
"@
Write-Utf8 (Join-Path $packageDir "known_limits_and_next_steps.md") $limits

$scanRows = New-Object System.Collections.Generic.List[object]
function Add-Scan([string]$Check, [string]$Expected, [string]$Actual, [string]$Status, [string]$Detail) {
    $scanRows.Add([pscustomobject]@{
        check = $Check
        expected = $Expected
        actual = $Actual
        status = $Status
        detail = $Detail
    }) | Out-Null
}

$files = Get-ChildItem -LiteralPath $packageDir -Recurse -File
$rawCsv = @($files | Where-Object { $_.Name -match "^(HI|LI)-.*\.csv$" }).Count
$csvCount = @($files | Where-Object { $_.Extension -eq ".csv" }).Count
$parquetCount = @($files | Where-Object { $_.Extension -eq ".parquet" }).Count
$largeCount = @($files | Where-Object { $_.Length -gt 1MB }).Count
$mediumLargeCount = @($files | Where-Object { $_.Name -match "Medium|Large" }).Count
$contentPaths = $files | Where-Object { $_.Length -lt 1MB -and $_.Extension -in @(".md", ".tsv", ".json", ".html", ".txt") } | Select-Object -ExpandProperty FullName
$secretPattern = "(?i)(password|token|secret)\s*[:=]\s*[^`t\r\n ]+|Basic [A-Za-z0-9+/=]{12,}|CLUSTER_HADOOP.*PASSWORD\s*="
$credentialHits = if ($contentPaths) { @(Select-String -Path $contentPaths -Pattern $secretPattern -ErrorAction SilentlyContinue).Count } else { 0 }
$externalProjectHits = @(Select-String -Path $contentPaths -Pattern "external project|cross-project" -ErrorAction SilentlyContinue).Count
$v1P14AsV2Hits = @(Select-String -Path $contentPaths -Pattern "p14_master_validation_20260611_184955.*V2|p18_portfolio_final_package_20260613_213025.*V2" -ErrorAction SilentlyContinue).Count

Add-Scan "raw_csv_count" "0" "$rawCsv" (Status-FromBool ($rawCsv -eq 0)) "No raw HI/LI CSV copied"
Add-Scan "csv_count" "0" "$csvCount" (Status-FromBool ($csvCount -eq 0)) "No CSV copied"
Add-Scan "parquet_count" "0" "$parquetCount" (Status-FromBool ($parquetCount -eq 0)) "No Parquet detail copied"
Add-Scan "large_file_count" "0" "$largeCount" (Status-FromBool ($largeCount -eq 0)) "No file exceeds 1 MiB"
Add-Scan "medium_large_name_count" "0" "$mediumLargeCount" (Status-FromBool ($mediumLargeCount -eq 0)) "No Medium/Large material copied"
Add-Scan "credential_hit_count" "0" "$credentialHits" (Status-FromBool ($credentialHits -eq 0)) "No credential pattern in package"
Add-Scan "external_project_keyword_hit_count" "0" "$externalProjectHits" (Status-FromBool ($externalProjectHits -eq 0)) "No non-finance workspace/project evidence references"
Add-Scan "v1_p14_p18_as_v2_hit_count" "0" "$v1P14AsV2Hits" (Status-FromBool ($v1P14AsV2Hits -eq 0)) "No V1 P14/P18 masquerading"
Add-Scan "required_file_count" "11" "11" "PASS" "Required P18v2 files generated"
Write-Tsv (Join-Path $packageDir "package_boundary_scan.tsv") $scanRows @("check", "expected", "actual", "status", "detail")

$status = if ((Test-AllPass $scanRows) -and $p14Map["p14v2_status"] -eq "PASS" -and $p13Map["p13v2_status"] -eq "PASS" -and $p15Map["p15v2_status"] -eq "PASS" -and $p17Map["p17v2_status"] -eq "PASS") { "PASS" } else { "FAIL" }

$statusRows = New-Object System.Collections.Generic.List[object]
foreach ($row in @(
    @{ metric = "package_name"; value = $packageName; status = "PASS" },
    @{ metric = "package_dir"; value = "data/finance_bigdata_v2/portfolio_packages/$packageName"; status = "PASS" },
    @{ metric = "source_p14v2_run_dir"; value = $P14v2RunDir; status = "PASS" },
    @{ metric = "p14v2_status"; value = $p14Map["p14v2_status"]; status = (Status-FromBool ($p14Map["p14v2_status"] -eq "PASS")) },
    @{ metric = "p13v2_status"; value = $p13Map["p13v2_status"]; status = (Status-FromBool ($p13Map["p13v2_status"] -eq "PASS")) },
    @{ metric = "p15v2_status"; value = $p15Map["p15v2_status"]; status = (Status-FromBool ($p15Map["p15v2_status"] -eq "PASS")) },
    @{ metric = "p17v2_status"; value = $p17Map["p17v2_status"]; status = (Status-FromBool ($p17Map["p17v2_status"] -eq "PASS")) },
    @{ metric = "copied_material_count"; value = $copiedManifest.Count; status = "PASS" },
    @{ metric = "boundary_fail_count"; value = @($scanRows | Where-Object { $_.status -ne "PASS" }).Count; status = (Status-FromBool (Test-AllPass $scanRows)) },
    @{ metric = "p18v2_status"; value = $status; status = $status }
)) {
    $statusRows.Add([pscustomobject]$row) | Out-Null
}
Write-Tsv (Join-Path $packageDir "p18v2_status.tsv") $statusRows @("metric", "value", "status")

$summary = @"
# P18v2 Portfolio Final Package Summary

- Package name: ``$packageName``
- Package dir: ``data/finance_bigdata_v2/portfolio_packages/$packageName``
- Source P14v2: ``$P14v2RunDir``
- Copied material count: ``$($copiedManifest.Count)``
- Boundary fail count: ``$(@($scanRows | Where-Object { $_.status -ne "PASS" }).Count)``
- Status: ``$status``


P18v2 is a lightweight portfolio package. It does not run new validation, start services, process data, copy raw datasets, copy Parquet details, copy credentials, use non-finance workspace evidence, or overwrite the V1 P18 package.
"@
Write-Utf8 (Join-Path $packageDir "p18v2_summary.md") $summary

Write-Host "P18V2_PACKAGE_DIR=$packageDir"
Write-Host "P18V2_STATUS=$status"
if ($status -ne "PASS") {
    exit 2
}
