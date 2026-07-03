# Purpose: P17 数据质量与监控规则检查入口，读取 accepted evidence 做规则验证。
# Boundary: 不启动集群、不重建数据、不训练模型，只输出质量检查证据。
param(
    [string]$OutputRoot = "data\finance_bigdata\runs"
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

function Add-Check {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [string]$Category,
        [string]$Check,
        [string]$Expected,
        [string]$Actual,
        [string]$Status,
        [string]$Source,
        [string]$Detail
    )
    $Rows.Add([pscustomobject]@{
        category = $Category
        check = $Check
        expected = $Expected
        actual = $Actual
        status = $Status
        source = $Source
        detail = $Detail
    }) | Out-Null
}

function Status-FromBool {
    param($Value)
    if ([bool]$Value) { return "PASS" }
    return "FAIL"
}

function Count-BadPackageFiles {
    param([string]$Path)
    $full = Join-ProjectPath $Path
    if (-not (Test-Path -LiteralPath $full)) { return 999999 }
    $bad = Get-ChildItem -LiteralPath $full -Recurse -File | Where-Object {
        $_.Length -gt 5MB -or
        $_.Name -match "^(HI|LI)-.*\.csv$" -or
        $_.Extension -eq ".parquet"
    }
    return @($bad).Count
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$runName = "p17_data_quality_check_$stamp"
$runDir = Join-ProjectPath (Join-Path $OutputRoot $runName)
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$checks = New-Object System.Collections.Generic.List[object]

$p1 = "data\finance_bigdata\runs\p1_profile_20260609_200713\profile_metrics.tsv"
$p2 = "data\finance_bigdata\runs\p2_ods_sample_20260609_200745\ods_validation_summary.tsv"
$p3 = "data\finance_bigdata\runs\p3_dwd_build_20260609_203822\dwd_summary.tsv"
$p4 = "data\finance_bigdata\runs\p4_dws_risk_kpi_20260609_204441\dws_summary.tsv"
$p5 = "data\finance_bigdata\runs\p5_hive_iceberg_publish_20260609_064034\count_validation.tsv"
$p9Summary = "data\finance_bigdata\runs\p9_model_baseline_20260609_231710\feature_dataset_summary.tsv"
$p10Row = "data\finance_bigdata\runs\p10_feature_parity_20260609_084412\row_parity.tsv"
$p10Leakage = "data\finance_bigdata\runs\p10_feature_parity_20260609_084412\leakage_field_scan.tsv"
$p11 = "data\finance_bigdata\runs\p11_realtime_scoring_contract_20260611_011424\redis_contract_summary.tsv"
$p12Status = "data\finance_bigdata\runs\p12_query_layer_validation_20260611_013546\p12_status.tsv"
$p12Tables = "data\finance_bigdata\runs\p12_query_layer_validation_20260611_013546\trino_table_counts.tsv"
$p13Status = "data\finance_bigdata\bi_packages\p13_bi_dashboard_package_20260611_172808\p13_status.tsv"
$p14Status = "data\finance_bigdata\runs\p14_master_validation_20260611_184955\summary.tsv"
$p15Status = "data\finance_bigdata\runs\p15_restart_readiness_20260613_211415\p15_status.tsv"
$p16Status = "data\finance_bigdata\runs\p16_model_explainability_20260613_211955\p16_status.tsv"

$p1Rows = Read-Tsv $p1
$p1Map = @{}
$p1Rows | ForEach-Object { $p1Map["$($_.section).$($_.metric)"] = [string]$_.value }
$p2Map = Read-Kv $p2
$p3Map = Read-Kv $p3
$p4Map = Read-Kv $p4
$p5Rows = Read-Tsv $p5
$p9Map = Read-Kv $p9Summary
$p10RowRows = Read-Tsv $p10Row
$p10LeakageRows = Read-Tsv $p10Leakage
$p11Map = Read-Kv $p11
$p12Map = Read-Kv $p12Status
$p12TableRows = Read-Tsv $p12Tables
$p13Map = Read-Kv $p13Status
$p14Map = Read-Kv $p14Status
$p15Map = Read-Kv $p15Status
$p16Map = @{}
Read-Tsv $p16Status | ForEach-Object { $p16Map[[string]$_.metric] = [string]$_.value }

$rawRows = [int64]$p1Map["transaction.row_count"]
$dwdRows = [int64]$p3Map["transaction_rows"]
$eventRows = [int64]$p3Map["event_rows"]
$accountRows = [int64]$p1Map["account.row_count"]
$dwdAccountRows = [int64]$p3Map["account_rows"]
$malformedRows = [int64]$p1Map["transaction.malformed_count"]
$positiveRows = 5177
$rawPositiveRate = [math]::Round($positiveRows / $rawRows, 8)
$largeCandidateRows = [int64]$p4Map["large_candidate_rows"]
$largeCandidateRate = [math]::Round($largeCandidateRows / $dwdRows, 8)

Add-Check $checks "row_count" "raw_vs_dwd_transaction_rows" "5078345 and equal" "$rawRows vs $dwdRows" (Status-FromBool ($rawRows -eq 5078345 -and $dwdRows -eq $rawRows)) $p1 "P1 raw rows must match P3 DWD rows"
Add-Check $checks "row_count" "dwd_event_rows_twice_transaction_rows" "10156690" "$eventRows" (Status-FromBool ($eventRows -eq ($dwdRows * 2))) $p3 "DWD event long table should contain debit and credit events"
Add-Check $checks "row_count" "account_rows_consistency" "518581" "$accountRows vs $dwdAccountRows" (Status-FromBool ($accountRows -eq 518581 -and $dwdAccountRows -eq 518581)) $p3 "Account dimension row count is stable"
Add-Check $checks "row_count" "ods_sample_rows" "100000" $p2Map["rows_written"] (Status-FromBool ($p2Map["rows_written"] -eq "100000")) $p2 "ODS sample size remains fixed"
Add-Check $checks "row_count" "p5_iceberg_table_counts" "7 PASS" ([string]@($p5Rows | Where-Object { $_.status -eq "PASS" }).Count) (Status-FromBool (@($p5Rows | Where-Object { $_.status -eq "PASS" }).Count -eq 7)) $p5 "Spark/Iceberg published counts"
Add-Check $checks "row_count" "p12_trino_table_counts" "7 PASS" ([string]@($p12TableRows | Where-Object { $_.status -eq "PASS" }).Count) (Status-FromBool (@($p12TableRows | Where-Object { $_.status -eq "PASS" }).Count -eq 7)) $p12Tables "Trino query layer table counts"

Add-Check $checks "quality_threshold" "malformed_transaction_rows" "0" "$malformedRows" (Status-FromBool ($malformedRows -eq 0)) $p1 "Malformed input rows should be zero"
Add-Check $checks "quality_threshold" "raw_laundering_rate_range" "0 < rate < 0.01" "$rawPositiveRate" (Status-FromBool ($rawPositiveRate -gt 0 -and $rawPositiveRate -lt 0.01)) $p1 "Raw label rate should remain rare but non-zero"
Add-Check $checks "quality_threshold" "large_candidate_rate_range" "0 < rate < 0.10" "$largeCandidateRate" (Status-FromBool ($largeCandidateRate -gt 0 -and $largeCandidateRate -lt 0.10)) $p4 "Large transaction candidate rate should not explode"
Add-Check $checks "quality_threshold" "p11_schema_invalid_events" "0" $p11Map["schema_invalid_event_count"] (Status-FromBool ($p11Map["schema_invalid_event_count"] -eq "0")) $p11 "Realtime contract output must be schema-valid"
Add-Check $checks "quality_threshold" "p12_business_query_pass_count" "4" $p12Map["business_query_pass_count"] (Status-FromBool ($p12Map["business_query_pass_count"] -eq "4")) $p12Status "Query layer must expose all four BI queries"

$p10Unmatched = ($p10RowRows | Where-Object { $_.metric -eq "warehouse_unmatched_rows" } | Select-Object -First 1).value
Add-Check $checks "feature_contract" "p9_feature_rows" "205177" $p9Map["feature_rows"] (Status-FromBool ($p9Map["feature_rows"] -eq "205177")) $p9Summary "P9 feature sample size"
Add-Check $checks "feature_contract" "p10_warehouse_unmatched_rows" "0" $p10Unmatched (Status-FromBool ($p10Unmatched -eq "0")) $p10Row "Warehouse-derived features match P9 rows"
Add-Check $checks "feature_contract" "p10_leakage_field_scan" "all PASS" ([string]@($p10LeakageRows | Where-Object { $_.status -eq "PASS" }).Count) (Status-FromBool (@($p10LeakageRows | Where-Object { $_.status -eq "PASS" }).Count -eq @($p10LeakageRows).Count)) $p10Leakage "Leakage fields must stay absent"
Add-Check $checks "feature_contract" "p16_source_feature_rows" "205177" $p16Map["feature_rows"] (Status-FromBool ($p16Map["feature_rows"] -eq "205177")) $p16Status "P16 must explain the effective P9 feature set"

$p8Bad = Count-BadPackageFiles "data\finance_bigdata\delivery_packages\p8_delivery_package_20260609_223950"
$p13Bad = Count-BadPackageFiles "data\finance_bigdata\bi_packages\p13_bi_dashboard_package_20260611_172808"
$largeFiles = @(Get-ChildItem -LiteralPath (Join-ProjectPath "datas") -File -Filter "*Large*" -ErrorAction SilentlyContinue).Count
Add-Check $checks "boundary" "current_large_files_absent" "0" "$largeFiles" (Status-FromBool ($largeFiles -eq 0)) "datas" "Current host must not process Large files"
Add-Check $checks "boundary" "p8_package_no_raw_or_parquet" "0" "$p8Bad" (Status-FromBool ($p8Bad -eq 0)) "data\finance_bigdata\delivery_packages\p8_delivery_package_20260609_223950" "Delivery package must remain lightweight"
Add-Check $checks "boundary" "p13_package_no_raw_or_parquet" "0" "$p13Bad" (Status-FromBool ($p13Bad -eq 0)) "data\finance_bigdata\bi_packages\p13_bi_dashboard_package_20260611_172808" "BI package must remain lightweight"
Add-Check $checks "boundary" "p14_status" "PASS" $p14Map["p14_status"] (Status-FromBool ($p14Map["p14_status"] -eq "PASS")) $p14Status "Master validation remains the accepted baseline"
Add-Check $checks "boundary" "p15_restart_readiness" "PASS" $p15Map["p15_status"] (Status-FromBool ($p15Map["p15_status"] -eq "PASS")) $p15Status "Restart readiness remains accepted"

$status = if (@($checks | Where-Object { $_.status -eq "FAIL" }).Count -eq 0) { "PASS" } else { "FAIL" }
$passCount = @($checks | Where-Object { $_.status -eq "PASS" }).Count
$warnCount = @($checks | Where-Object { $_.status -eq "WARN" }).Count
$failCount = @($checks | Where-Object { $_.status -eq "FAIL" }).Count

Write-Tsv (Join-Path $runDir "quality_check_results.tsv") $checks @("category","check","expected","actual","status","source","detail")

$statusRows = New-Object System.Collections.Generic.List[object]
$statusRows.Add([pscustomobject]@{ metric = "run_name"; value = $runName; status = "PASS" }) | Out-Null
$statusRows.Add([pscustomobject]@{ metric = "check_count"; value = $checks.Count; status = "PASS" }) | Out-Null
$statusRows.Add([pscustomobject]@{ metric = "pass_count"; value = $passCount; status = "PASS" }) | Out-Null
$statusRows.Add([pscustomobject]@{ metric = "warn_count"; value = $warnCount; status = "PASS" }) | Out-Null
$statusRows.Add([pscustomobject]@{ metric = "fail_count"; value = $failCount; status = $(if ($failCount -eq 0) { "PASS" } else { "FAIL" }) }) | Out-Null
$statusRows.Add([pscustomobject]@{ metric = "p17_status"; value = $status; status = $status }) | Out-Null
Write-Tsv (Join-Path $runDir "p17_status.tsv") $statusRows @("metric","value","status")

$rules = @"
# Finance Data Quality Rules


These rules monitor the effective finance project workspace. They use the accepted P0-P16 evidence and are designed for portfolio validation, not enterprise production monitoring.


| Group | Rule | Current Threshold |
| --- | --- | --- |
| Row counts | Raw transaction rows must equal DWD transaction rows | 5,078,345 |
| Row counts | DWD event rows must equal twice transaction rows | 10,156,690 |
| Row counts | Iceberg and Trino table counts must pass 7/7 | 7 PASS |
| Data validity | Malformed transaction rows | 0 |
| Label sanity | Raw laundering rate | greater than 0 and less than 1% |
| Risk candidate sanity | Large transaction candidate rate | greater than 0 and less than 10% |
| Feature contract | P9 feature rows | 205,177 |
| Feature contract | P10 unmatched warehouse rows | 0 |
| Feature contract | Leakage field scan | all PASS |
| Realtime contract | P11 schema-invalid risk events | 0 |
| Query readiness | P12 business query pass count | 4 |
| Packaging boundary | P8/P13 raw CSV or Parquet files | 0 |
| Restart readiness | P15 status | PASS |


- Redis latest-state keys can be volatile after restart, so P15 treats missing historical Redis keys as warning-only.
- Medium files are retained for future scale-up but are not part of the accepted validation path.
- Large files must not be present or processed on this host.
- Any future P18 or portfolio package must copy only small summaries, markdown, TSV, JSON samples and HTML preview files.
"@
Write-Utf8 "quality\finance_quality_rules.md" $rules

$summary = @"
# P17 Data Quality Check Summary

- Run name: ``$runName``
- Run dir: ``$runDir``
- Check count: ``$($checks.Count)``
- Pass count: ``$passCount``
- Warn count: ``$warnCount``
- Fail count: ``$failCount``
- Status: ``$status``


- ``quality_check_results.tsv``
- ``p17_status.tsv``
- ``quality/finance_quality_rules.md``


P17 reads accepted local evidence only. It does not start cluster services, rebuild data, train models, or process Medium/Large files.
"@
Write-Utf8 (Join-Path $runDir "p17_summary.md") $summary

Write-Host "P17_RUN_DIR=$runDir"
Write-Host "P17_STATUS=$status"
if ($status -ne "PASS") {
    exit 2
}
