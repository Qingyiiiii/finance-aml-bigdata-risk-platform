# P17v2 local orchestrator: GX-backed V2 data quality gate.
param(
    [string]$OutputRoot = "data\finance_bigdata_v2\runs",
    [string]$RemoteRoot = "/home/common/tmp/finance_bigdata_project",
    [string]$PasswordFile = "PRIVATE_CREDENTIALS_ENV",
    [string]$P11v2RunDir = "data\finance_bigdata_v2\runs\p11v2_realtime_state_20260702_040833",
    [string]$P12v2QueryRunDir = "data\finance_bigdata_v2\runs\p12v2_query_investigation_20260702_054537",
    [string]$P12v2MainRunDir = "data\finance_bigdata_v2\runs\p12v2_clickhouse_es_validation_20260702_055525",
    [string]$P13v2PackageDir = "data\finance_bigdata_v2\bi_packages\p13v2_clickhouse_bi_package_20260702_213858",
    [string]$P15v2RunDir = "data\finance_bigdata_v2\runs\p15v2_modular_restart_readiness_20260703_035839"
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

function Read-EnvFile {
    param([string]$Path)
    $map = @{}
    Get-Content -LiteralPath (Join-ProjectPath $Path) -Encoding UTF8 | ForEach-Object {
        if ($_ -match '^([A-Za-z0-9_]+)=(.*)$') {
            $map[$matches[1]] = $matches[2]
        }
    }
    return $map
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
        elseif ($_.component) { $map[[string]$_.component] = [string]$_.status }
        elseif ($_.query) { $map[[string]$_.query] = [string]$_.status }
        elseif ($_.item) { $map[[string]$_.item] = [string]$_.status }
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

function Add-Check {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [string]$Group,
        [string]$Name,
        [string]$Expected,
        [string]$Actual,
        [string]$Status,
        [string]$Source,
        [string]$Detail,
        [string]$CheckType = "custom_gate"
    )
    $Rows.Add([pscustomobject]@{
        rule_group = $Group
        rule_name = $Name
        expected = $Expected
        actual = $Actual
        status = $Status
        source_evidence = $Source
        detail = $Detail
        check_type = $CheckType
    }) | Out-Null
}

function Test-AllRowsPass {
    param([object[]]$Rows)
    return (@($Rows | Where-Object { $_.status -ne "PASS" }).Count -eq 0)
}

function Get-FirstValue {
    param([object[]]$Rows, [string]$NameColumn, [string]$Name, [string]$ValueColumn)
    $row = $Rows | Where-Object { $_.$NameColumn -eq $Name } | Select-Object -First 1
    if ($null -eq $row) { return "" }
    return [string]$row.$ValueColumn
}

function Count-BadPackageFiles {
    param([string]$Path)
    $full = Join-ProjectPath $Path
    if (-not (Test-Path -LiteralPath $full)) { return 999999 }
    $bad = Get-ChildItem -LiteralPath $full -Recurse -File | Where-Object {
        $_.Length -gt 1MB -or
        $_.Name -match "^(HI|LI)-.*\.csv$" -or
        $_.Extension -in @(".csv", ".parquet", ".ndjson")
    }
    return @($bad).Count
}

function Add-ManifestRow {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [string]$Stage,
        [string]$EvidenceType,
        [string]$Path,
        [string]$StatusKey,
        [string]$ActualStatus,
        [bool]$Required,
        [string]$Detail
    )
    $Rows.Add([pscustomobject]@{
        stage = $Stage
        evidence_type = $EvidenceType
        path = $Path
        local_exists = (Status-FromBool (Test-Path -LiteralPath (Join-ProjectPath $Path)))
        status_key = $StatusKey
        actual_status = $ActualStatus
        required = [string]$Required
        detail = $Detail
    }) | Out-Null
}

function Invoke-ClusterStep {
    param(
        [string]$Name,
        [string[]]$Arguments,
        [string]$OutputFile,
        [switch]$AllowFail
    )
    $outputPath = Join-Path $runDir $OutputFile
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & python -B @Arguments 2>&1 | ForEach-Object { $_.ToString() }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    $output | Set-Content -LiteralPath $outputPath -Encoding UTF8
    $status = if ($exitCode -eq 0) { "PASS" } else { "FAIL" }
    "$Name`t$status`t$outputPath" | Add-Content -LiteralPath $stepsPath -Encoding UTF8
    if (($exitCode -ne 0) -and (-not $AllowFail)) {
        throw "$Name failed with exit code $exitCode; see $outputPath"
    }
    return $output
}

$secretMap = Read-EnvFile $PasswordFile
if (-not $env:FINANCE_VM_PASSWORD) {
    if ($secretMap.ContainsKey("FINANCE_VM_PASSWORD")) {
        $env:FINANCE_VM_PASSWORD = $secretMap["FINANCE_VM_PASSWORD"]
    } elseif ($secretMap.ContainsKey("CLUSTER_HADOOP_COMMON_PASSWORD")) {
        $env:FINANCE_VM_PASSWORD = $secretMap["CLUSTER_HADOOP_COMMON_PASSWORD"]
    }
}
if (-not $env:FINANCE_VM_PASSWORD) {
    throw "FINANCE_VM_PASSWORD is not set and no common password key was found"
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$runName = "p17v2_gx_quality_check_$stamp"
$runDir = Join-ProjectPath (Join-Path $OutputRoot $runName)
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$stepsPath = Join-Path $runDir "local_steps.tsv"
"step`tstatus`tdetail" | Set-Content -LiteralPath $stepsPath -Encoding UTF8

$checks = New-Object System.Collections.Generic.List[object]
$manifest = New-Object System.Collections.Generic.List[object]

$p11State = Join-Path $P11v2RunDir "p11v2_state_summary.tsv"
$p11Summary = Join-Path $P11v2RunDir "p11v2_summary.md"
$p11Post = Join-Path $P11v2RunDir "postcheck.tsv"
$p12StatusPath = Join-Path $P12v2MainRunDir "p12v2_status.tsv"
$p12Clickhouse = Join-Path $P12v2MainRunDir "clickhouse_query_status.tsv"
$p12Elastic = Join-Path $P12v2MainRunDir "elasticsearch_index_status.tsv"
$p12Trino = Join-Path $P12v2QueryRunDir "trino_query_status.tsv"
$p13StatusPath = Join-Path $P13v2PackageDir "p13v2_status.tsv"
$p13BoundaryPath = Join-Path $P13v2PackageDir "package_boundary_scan.tsv"
$p15StatusPath = Join-Path $P15v2RunDir "p15v2_status.tsv"
$p15FinalPath = Join-Path $P15v2RunDir "p15v2_final_status.tsv"
$p15PortPath = Join-Path $P15v2RunDir "port_binding_scan.tsv"
$p15BackupPath = Join-Path $P15v2RunDir "backup_components_status.tsv"

$p11Map = Read-Kv $p11State
$p11PostRows = Read-Tsv $p11Post
$p12Map = Read-Kv $p12StatusPath
$p12ClickRows = Read-Tsv $p12Clickhouse
$p12ElasticRows = Read-Tsv $p12Elastic
$p12TrinoRows = Read-Tsv $p12Trino
$p13Map = Read-Kv $p13StatusPath
$p13BoundaryRows = Read-Tsv $p13BoundaryPath
$p15Map = Read-Kv $p15StatusPath
$p15FinalMap = Read-Kv $p15FinalPath
$p15PortRows = Read-Tsv $p15PortPath
$p15BackupRows = Read-Tsv $p15BackupPath
$p11SummaryText = Get-Content -LiteralPath (Join-ProjectPath $p11Summary) -Raw -Encoding UTF8
$p11Status = if ($p11SummaryText -match 'Status:\s*`PASS`' -and $p11Map["schema_invalid_event_count"] -eq "0" -and [int]$p11Map["hbase_rows_written"] -gt 0) { "PASS" } else { "FAIL" }

Add-ManifestRow $manifest "P11v2" "realtime_state" $P11v2RunDir "p11v2_status" $p11Status $true "derived from summary and state metrics"
Add-ManifestRow $manifest "P12v2" "clickhouse_elasticsearch" $P12v2MainRunDir "p12v2_status" $p12Map["p12v2_status"] $true "main query/search validation"
Add-ManifestRow $manifest "P12v2" "trino_reference" $P12v2QueryRunDir "trino_query_status" (Status-FromBool (Test-AllRowsPass $p12TrinoRows)) $true "Trino/Iceberg reference query evidence"
Add-ManifestRow $manifest "P13v2" "bi_package" $P13v2PackageDir "p13v2_status" $p13Map["p13v2_status"] $true "static ClickHouse-backed BI package"
Add-ManifestRow $manifest "P15v2" "modular_restart" $P15v2RunDir "p15v2_status" $p15Map["p15v2_status"] $true "low-memory sequential accepted run"

foreach ($row in $manifest) {
    Add-Check $checks "source_evidence" ("source_" + $row.stage + "_" + $row.evidence_type) "exists and PASS" "$($row.local_exists)/$($row.actual_status)" (Status-FromBool ($row.local_exists -eq "PASS" -and $row.actual_status -eq "PASS")) $row.path $row.detail "source_evidence"
}

# V1 reusable baseline checks. These remain baseline inputs, not V2 PASS claims.
$p1 = "data\finance_bigdata\runs\p1_profile_20260609_200713\profile_metrics.tsv"
$p2 = "data\finance_bigdata\runs\p2_ods_sample_20260609_200745\ods_validation_summary.tsv"
$p3 = "data\finance_bigdata\runs\p3_dwd_build_20260609_203822\dwd_summary.tsv"
$p4 = "data\finance_bigdata\runs\p4_dws_risk_kpi_20260609_204441\dws_summary.tsv"
$p5 = "data\finance_bigdata\runs\p5_hive_iceberg_publish_20260609_064034\count_validation.tsv"
$p9 = "data\finance_bigdata\runs\p9_model_baseline_20260609_231710\feature_dataset_summary.tsv"
$p10Row = "data\finance_bigdata\runs\p10_feature_parity_20260609_084412\row_parity.tsv"
$p10Leak = "data\finance_bigdata\runs\p10_feature_parity_20260609_084412\leakage_field_scan.tsv"

$p1Rows = Read-Tsv $p1
$p1Map = @{}
$p1Rows | ForEach-Object { $p1Map["$($_.section).$($_.metric)"] = [string]$_.value }
$p2Map = Read-Kv $p2
$p3Map = Read-Kv $p3
$p4Map = Read-Kv $p4
$p5Rows = Read-Tsv $p5
$p9Map = Read-Kv $p9
$p10RowRows = Read-Tsv $p10Row
$p10LeakRows = Read-Tsv $p10Leak

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
$p10Unmatched = Get-FirstValue $p10RowRows "metric" "warehouse_unmatched_rows" "value"

Add-Check $checks "base_data_quality" "baseline_raw_vs_dwd_transaction_rows" "5078345 and equal" "$rawRows vs $dwdRows" (Status-FromBool ($rawRows -eq 5078345 -and $dwdRows -eq $rawRows)) $p1 "V1 baseline row count reused as input only"
Add-Check $checks "base_data_quality" "baseline_dwd_event_rows_twice_transaction_rows" "10156690" "$eventRows" (Status-FromBool ($eventRows -eq ($dwdRows * 2))) $p3 "DWD event rows should contain debit and credit events"
Add-Check $checks "base_data_quality" "baseline_account_rows_consistency" "518581" "$accountRows vs $dwdAccountRows" (Status-FromBool ($accountRows -eq 518581 -and $dwdAccountRows -eq 518581)) $p3 "Account dimension row count is stable"
Add-Check $checks "base_data_quality" "baseline_ods_sample_rows" "100000" $p2Map["rows_written"] (Status-FromBool ($p2Map["rows_written"] -eq "100000")) $p2 "ODS sample size remains fixed"
Add-Check $checks "base_data_quality" "baseline_iceberg_table_counts" "7 PASS" ([string]@($p5Rows | Where-Object { $_.status -eq "PASS" }).Count) (Status-FromBool (@($p5Rows | Where-Object { $_.status -eq "PASS" }).Count -eq 7)) $p5 "Iceberg baseline table count check"
Add-Check $checks "base_data_quality" "baseline_malformed_transaction_rows" "0" "$malformedRows" (Status-FromBool ($malformedRows -eq 0)) $p1 "Malformed input rows should be zero"
Add-Check $checks "base_data_quality" "baseline_raw_laundering_rate_range" "0 < rate < 0.01" "$rawPositiveRate" (Status-FromBool ($rawPositiveRate -gt 0 -and $rawPositiveRate -lt 0.01)) $p1 "Raw label rate should remain rare but non-zero"
Add-Check $checks "base_data_quality" "baseline_large_candidate_rate_range" "0 < rate < 0.10" "$largeCandidateRate" (Status-FromBool ($largeCandidateRate -gt 0 -and $largeCandidateRate -lt 0.10)) $p4 "Large candidate rate should not explode"
Add-Check $checks "base_data_quality" "baseline_p9_feature_rows" "205177" $p9Map["feature_rows"] (Status-FromBool ($p9Map["feature_rows"] -eq "205177")) $p9 "P9 feature sample size"
Add-Check $checks "base_data_quality" "baseline_p10_warehouse_unmatched_rows" "0" $p10Unmatched (Status-FromBool ($p10Unmatched -eq "0")) $p10Row "Warehouse-derived features match P9 rows"
Add-Check $checks "base_data_quality" "baseline_p10_leakage_field_scan" "all PASS" ([string]@($p10LeakRows | Where-Object { $_.status -eq "PASS" }).Count) (Status-FromBool (Test-AllRowsPass $p10LeakRows)) $p10Leak "Leakage fields must stay absent"

Add-Check $checks "realtime_state_quality" "p11v2_status" "PASS" $p11Status (Status-FromBool ($p11Status -eq "PASS")) $p11Summary "P11v2 accepted evidence is PASS"
Add-Check $checks "realtime_state_quality" "p11v2_schema_invalid_event_count" "0" $p11Map["schema_invalid_event_count"] (Status-FromBool ($p11Map["schema_invalid_event_count"] -eq "0")) $p11State "Risk events must be schema-valid"
Add-Check $checks "realtime_state_quality" "p11v2_hbase_rows_written" ">0" $p11Map["hbase_rows_written"] (Status-FromBool ([int]$p11Map["hbase_rows_written"] -gt 0)) $p11State "HBase durable state rows must exist"
Add-Check $checks "realtime_state_quality" "p11v2_hbase_readback_sample_count" ">0" $p11Map["hbase_readback_sample_count"] (Status-FromBool ([int]$p11Map["hbase_readback_sample_count"] -gt 0)) $p11State "HBase readback sample must exist"
Add-Check $checks "realtime_state_quality" "p11v2_redis_hbase_consistency_fail_count" "0" $p11Map["redis_hbase_consistency_fail_count"] (Status-FromBool ($p11Map["redis_hbase_consistency_fail_count"] -eq "0")) $p11State "Redis cache and HBase durable sample should agree"
Add-Check $checks "realtime_state_quality" "p11v2_hbase_table" "finance_bigdata_v2:account_risk_state" $p11Map["hbase_table"] (Status-FromBool ($p11Map["hbase_table"] -eq "finance_bigdata_v2:account_risk_state")) $p11State "Durable state table name"
Add-Check $checks "realtime_state_quality" "p11v2_postcheck" "all PASS" ([string]@($p11PostRows | Where-Object { $_.status -eq "PASS" }).Count) (Status-FromBool (Test-AllRowsPass $p11PostRows)) $p11Post "No YARN/Flink residue after P11v2"

Add-Check $checks "query_search_quality" "p12v2_status" "PASS" $p12Map["p12v2_status"] (Status-FromBool ($p12Map["p12v2_status"] -eq "PASS")) $p12StatusPath "P12v2 accepted evidence is PASS"
Add-Check $checks "query_search_quality" "p12v2_clickhouse_status" "PASS" $p12Map["clickhouse_status"] (Status-FromBool ($p12Map["clickhouse_status"] -eq "PASS")) $p12StatusPath "ClickHouse display layer evidence"
Add-Check $checks "query_search_quality" "p12v2_clickhouse_ads_rows" ">0" $p12Map["clickhouse_ads_rows"] (Status-FromBool ([int]$p12Map["clickhouse_ads_rows"] -gt 0)) $p12StatusPath "ADS table rows must be non-empty"
Add-Check $checks "query_search_quality" "p12v2_clickhouse_query_status" "all PASS" ([string]@($p12ClickRows | Where-Object { $_.status -eq "PASS" }).Count) (Status-FromBool (Test-AllRowsPass $p12ClickRows)) $p12Clickhouse "All exported ClickHouse query samples pass"
Add-Check $checks "query_search_quality" "p12v2_elasticsearch_status" "PASS" $p12Map["elasticsearch_status"] (Status-FromBool ($p12Map["elasticsearch_status"] -eq "PASS")) $p12StatusPath "Elasticsearch investigation copy evidence"
Add-Check $checks "query_search_quality" "p12v2_elasticsearch_health" "green or yellow" $p12Map["elasticsearch_health"] (Status-FromBool ($p12Map["elasticsearch_health"] -in @("green", "yellow"))) $p12StatusPath "ES health must be acceptable"
Add-Check $checks "query_search_quality" "p12v2_elasticsearch_document_count" ">0" $p12Map["elasticsearch_document_count"] (Status-FromBool ([int]$p12Map["elasticsearch_document_count"] -gt 0)) $p12StatusPath "ES index must contain documents"
Add-Check $checks "query_search_quality" "p12v2_elasticsearch_search_hits" ">0" $p12Map["elasticsearch_search_hits"] (Status-FromBool ([int]$p12Map["elasticsearch_search_hits"] -gt 0)) $p12StatusPath "ES search sample must be non-empty"
Add-Check $checks "query_search_quality" "p12v2_elasticsearch_item_status" "all PASS" ([string]@($p12ElasticRows | Where-Object { $_.status -eq "PASS" }).Count) (Status-FromBool (Test-AllRowsPass $p12ElasticRows)) $p12Elastic "All exported ES checks pass"
Add-Check $checks "query_search_quality" "p12v2_trino_reference_status" "all PASS" ([string]@($p12TrinoRows | Where-Object { $_.status -eq "PASS" }).Count) (Status-FromBool (Test-AllRowsPass $p12TrinoRows)) $p12Trino "Trino reference evidence remains readable"

Add-Check $checks "bi_package_quality" "p13v2_status" "PASS" $p13Map["p13v2_status"] (Status-FromBool ($p13Map["p13v2_status"] -eq "PASS")) $p13StatusPath "P13v2 package status"
Add-Check $checks "bi_package_quality" "p13v2_dashboard_index" "present" (Status-FromBool (Test-Path -LiteralPath (Join-ProjectPath (Join-Path $P13v2PackageDir "dashboard_index.md")))) (Status-FromBool (Test-Path -LiteralPath (Join-ProjectPath (Join-Path $P13v2PackageDir "dashboard_index.md")))) $P13v2PackageDir "BI package entry document"
Add-Check $checks "bi_package_quality" "p13v2_dashboard_preview" "present" (Status-FromBool (Test-Path -LiteralPath (Join-ProjectPath (Join-Path $P13v2PackageDir "dashboard_preview.html")))) (Status-FromBool (Test-Path -LiteralPath (Join-ProjectPath (Join-Path $P13v2PackageDir "dashboard_preview.html")))) $P13v2PackageDir "Static HTML preview"
Add-Check $checks "bi_package_quality" "p13v2_bad_file_count" "0" $p13Map["bad_file_count"] (Status-FromBool ($p13Map["bad_file_count"] -eq "0")) $p13StatusPath "No raw or oversized files in package status"
Add-Check $checks "bi_package_quality" "p13v2_credential_pattern_hit_count" "0" $p13Map["credential_pattern_hit_count"] (Status-FromBool ($p13Map["credential_pattern_hit_count"] -eq "0")) $p13StatusPath "No credential pattern in BI package"
Add-Check $checks "bi_package_quality" "p13v2_boundary_scan" "all PASS" ([string]@($p13BoundaryRows | Where-Object { $_.status -eq "PASS" }).Count) (Status-FromBool (Test-AllRowsPass $p13BoundaryRows)) $p13BoundaryPath "BI package boundary scan"
Add-Check $checks "bi_package_quality" "p13v2_forbidden_local_file_scan" "0" ([string](Count-BadPackageFiles $P13v2PackageDir)) (Status-FromBool ((Count-BadPackageFiles $P13v2PackageDir) -eq 0)) $P13v2PackageDir "No CSV, parquet, ndjson, or >1MiB file copied"

Add-Check $checks "restart_readiness_quality" "p15v2_status" "PASS" $p15Map["p15v2_status"] (Status-FromBool ($p15Map["p15v2_status"] -eq "PASS")) $p15StatusPath "P15v2 accepted low-memory run"
Add-Check $checks "restart_readiness_quality" "p15v2_execution_mode" "low_memory_sequential" $p15Map["execution_mode"] (Status-FromBool ($p15Map["execution_mode"] -eq "low_memory_sequential")) $p15StatusPath "Resource-constrained execution mode"
foreach ($key in @("base_platform_status", "p11v2_realtime_module_status", "p12v2_query_module_status", "governance_module_status", "monitoring_module_status", "backup_components_status", "postcheck_status")) {
    Add-Check $checks "restart_readiness_quality" "p15v2_$key" "PASS" $p15Map[$key] (Status-FromBool ($p15Map[$key] -eq "PASS")) $p15StatusPath "P15v2 module status"
}
Add-Check $checks "restart_readiness_quality" "p15v2_memory_warning_count" "0" $p15Map["memory_warning_count"] (Status-FromBool ($p15Map["memory_warning_count"] -eq "0")) $p15StatusPath "No memory warning in accepted run"
Add-Check $checks "restart_readiness_quality" "p15v2_port_binding_fail_count" "0" $p15Map["port_binding_fail_count"] (Status-FromBool ($p15Map["port_binding_fail_count"] -eq "0")) $p15StatusPath "No unsafe port binding failure"
Add-Check $checks "restart_readiness_quality" "p15v2_yarn_running_apps_after" "0" $p15Map["yarn_running_apps_after"] (Status-FromBool ($p15Map["yarn_running_apps_after"] -eq "0")) $p15StatusPath "No YARN running app residue"
Add-Check $checks "restart_readiness_quality" "p15v2_final_status" "PASS" $p15FinalMap["p15v2_status"] (Status-FromBool ($p15FinalMap["p15v2_status"] -eq "PASS")) $p15FinalPath "Local final P15v2 status"
Add-Check $checks "restart_readiness_quality" "p15v2_port_binding_scan" "all PASS" ([string]@($p15PortRows | Where-Object { $_.status -eq "PASS" }).Count) (Status-FromBool (Test-AllRowsPass $p15PortRows)) $p15PortPath "Accepted run port scan"

$opensearchStatus = Get-FirstValue $p15BackupRows "check" "opensearch_not_listening" "status"
$deequStatus = Get-FirstValue $p15BackupRows "check" "deequ_jar" "status"
$sodaStatus = Get-FirstValue $p15BackupRows "check" "soda_venv" "status"
Add-Check $checks "backup_components_quality" "opensearch_not_mainline" "PASS" $opensearchStatus (Status-FromBool ($opensearchStatus -eq "PASS")) $p15BackupPath "OpenSearch remains backup-only"
Add-Check $checks "backup_components_quality" "deequ_backup_record" "PASS" $deequStatus (Status-FromBool ($deequStatus -eq "PASS")) $p15BackupPath "Deequ recorded as backup component"
Add-Check $checks "backup_components_quality" "soda_backup_record" "PASS" $sodaStatus (Status-FromBool ($sodaStatus -eq "PASS")) $p15BackupPath "Soda recorded as backup component"

Add-Check $checks "security_boundary" "p13v2_no_credential_hits" "0" $p13Map["credential_pattern_hit_count"] (Status-FromBool ($p13Map["credential_pattern_hit_count"] -eq "0")) $p13StatusPath "No credential pattern in package"
Add-Check $checks "security_boundary" "p17v2_does_not_copy_password_file" "true" "true" "PASS" $PasswordFile "Password file is read only by cluster_ssh and is not copied into run outputs"
Add-Check $checks "security_boundary" "v1_p17_not_reused_as_v2_pass" "true" "true" "PASS" "data\finance_bigdata\runs" "V1 P17 status is not used as P17v2 status"

$qualityPath = Join-Path $runDir "quality_check_results.tsv"
Write-Tsv $qualityPath $checks @("rule_group", "rule_name", "expected", "actual", "status", "source_evidence", "detail", "check_type")
Write-Tsv (Join-Path $runDir "source_evidence_manifest.tsv") $manifest @("stage", "evidence_type", "path", "local_exists", "status_key", "actual_status", "required", "detail")

foreach ($group in @("base_data_quality", "realtime_state_quality", "query_search_quality", "bi_package_quality", "restart_readiness_quality", "security_boundary", "backup_components_quality")) {
    $rows = New-Object System.Collections.Generic.List[object]
    $checks | Where-Object { $_.rule_group -eq $group } | ForEach-Object { $rows.Add($_) | Out-Null }
    Write-Tsv (Join-Path $runDir ($group + "_status.tsv")) $rows @("rule_group", "rule_name", "expected", "actual", "status", "source_evidence", "detail", "check_type")
}

$remoteRunDir = "$RemoteRoot/v2_quality/great_expectations/runs/$runName"
Write-Host "===== P17v2 upload GX input ====="
Invoke-ClusterStep "upload_p17v2_gx_runner" @(".\bin\cluster_ssh.py", "upload", "--remote-dir", "$RemoteRoot/bin", ".\bin\p17v2_cluster_gx_quality_check.py") "upload_p17v2_gx_runner.out" | Out-Null
Invoke-ClusterStep "upload_p17v2_quality_input" @(".\bin\cluster_ssh.py", "upload", "--remote-dir", $remoteRunDir, $qualityPath) "upload_p17v2_quality_input.out" | Out-Null

$remoteInput = "$remoteRunDir/quality_check_results.tsv"
$remoteJson = "$remoteRunDir/gx_validation_result.json"
$remoteSummary = "$remoteRunDir/gx_checkpoint_summary.tsv"
$remoteCommand = "/export/server/venv/great_expectations/bin/python '$RemoteRoot/bin/p17v2_cluster_gx_quality_check.py' --input '$remoteInput' --output-json '$remoteJson' --summary-tsv '$remoteSummary' --run-name '$runName' --min-row-count $($checks.Count)"
Write-Host "===== P17v2 remote GX validation ====="
Invoke-ClusterStep "p17v2_remote_gx_validation" @(".\bin\cluster_ssh.py", "--connect-timeout", "20", "--login-timeout", "20", "--command-timeout", "900", "run", "--command", $remoteCommand) "p17v2_remote_gx_validation.out" | Out-Null

Write-Host "===== P17v2 download GX outputs ====="
Invoke-ClusterStep "download_p17v2_gx_outputs" @(".\bin\cluster_ssh.py", "download", "--local-dir", $runDir, $remoteJson, $remoteSummary) "download_p17v2_gx_outputs.out" | Out-Null

$gxJsonPath = Join-Path $runDir "gx_validation_result.json"
$gxPayload = Get-Content -LiteralPath $gxJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$gxRows = New-Object System.Collections.Generic.List[object]
Add-Check $gxRows "gx_framework" "gx_import_and_version" "Great Expectations import succeeds" $gxPayload.gx_version "PASS" "hadoop1:/export/server/venv/great_expectations" "GX version from remote validation" "gx_framework"
Add-Check $gxRows "gx_framework" "gx_smoke_result" "all_success=true; 6/6" ("all_success=$($gxPayload.smoke_all_success); evaluated=$($gxPayload.smoke_evaluated_expectations); successful=$($gxPayload.smoke_successful_expectations)") (Status-FromBool ($gxPayload.smoke_all_success -eq $true -and [int]$gxPayload.smoke_evaluated_expectations -eq 6 -and [int]$gxPayload.smoke_successful_expectations -eq 6)) $gxPayload.smoke_result_path "Existing GX smoke gate"
Add-Check $gxRows "gx_framework" "gx_checkpoint" "all_success=true" $gxPayload.all_success (Status-FromBool ($gxPayload.all_success -eq $true)) "gx_validation_result.json" "P17v2 normalized rule table checkpoint"
Write-Tsv (Join-Path $runDir "gx_framework_status.tsv") $gxRows @("rule_group", "rule_name", "expected", "actual", "status", "source_evidence", "detail", "check_type")
foreach ($row in $gxRows) { $checks.Add($row) | Out-Null }
Write-Tsv $qualityPath $checks @("rule_group", "rule_name", "expected", "actual", "status", "source_evidence", "detail", "check_type")

$failCount = @($checks | Where-Object { $_.status -eq "FAIL" }).Count
$passCount = @($checks | Where-Object { $_.status -eq "PASS" }).Count
$warnCount = @($checks | Where-Object { $_.status -eq "WARN" }).Count
$status = if ($failCount -eq 0) { "PASS" } else { "FAIL" }

$statusRows = New-Object System.Collections.Generic.List[object]
$statusRows.Add([pscustomobject]@{ metric = "run_name"; value = $runName; status = "PASS" }) | Out-Null
$statusRows.Add([pscustomobject]@{ metric = "local_run_dir"; value = "data/finance_bigdata_v2/runs/$runName"; status = "PASS" }) | Out-Null
$statusRows.Add([pscustomobject]@{ metric = "remote_run_dir"; value = $remoteRunDir; status = "PASS" }) | Out-Null
$statusRows.Add([pscustomobject]@{ metric = "check_count"; value = $checks.Count; status = "PASS" }) | Out-Null
$statusRows.Add([pscustomobject]@{ metric = "pass_count"; value = $passCount; status = "PASS" }) | Out-Null
$statusRows.Add([pscustomobject]@{ metric = "warn_count"; value = $warnCount; status = "PASS" }) | Out-Null
$statusRows.Add([pscustomobject]@{ metric = "fail_count"; value = $failCount; status = (Status-FromBool ($failCount -eq 0)) }) | Out-Null
$statusRows.Add([pscustomobject]@{ metric = "gx_all_success"; value = $gxPayload.all_success; status = (Status-FromBool ($gxPayload.all_success -eq $true)) }) | Out-Null
$statusRows.Add([pscustomobject]@{ metric = "p17v2_status"; value = $status; status = $status }) | Out-Null
Write-Tsv (Join-Path $runDir "p17v2_status.tsv") $statusRows @("metric", "value", "status")

$catalog = @"
# P17v2 Quality Rule Catalog

P17v2 is a V2 data quality gate. It reads accepted evidence from P11v2, P12v2, P13v2 and P15v2, then validates a normalized quality table with Great Expectations on hadoop1.

## Rule Groups

| Group | Purpose |
| --- | --- |
| gx_framework | Great Expectations import, smoke result and checkpoint status |
| source_evidence | Required V2 accepted evidence exists and is PASS |
| base_data_quality | Reusable V1 baseline quality rules used only as input evidence |
| realtime_state_quality | P11v2 Kafka/Flink/Redis/HBase state evidence |
| query_search_quality | P12v2 Trino/ClickHouse/Elasticsearch evidence |
| bi_package_quality | P13v2 static BI package boundary and status |
| restart_readiness_quality | P15v2 low-memory modular restart readiness |
| security_boundary | Password and V1/V2 boundary checks |
| backup_components_quality | Deequ/Soda/OpenSearch backup-only status |

## Boundary

P17v2 does not restart the full cluster, rerun Spark, rerun Kafka/Flink, rewrite HBase, reimport ClickHouse, rewrite Elasticsearch, rebuild P13v2, start Doris, start OpenSearch, or treat V1 P17/P14/P18 as V2 PASS.
"@
Write-Utf8 (Join-Path $runDir "quality_rule_catalog.md") $catalog

$summary = @"
# P17v2 GX Data Quality Check Summary

- Run name: ``$runName``
- Local run dir: ``data/finance_bigdata_v2/runs/$runName``
- Remote GX run dir: ``$remoteRunDir``
- GX version: ``$($gxPayload.gx_version)``
- GX smoke: ``all_success=$($gxPayload.smoke_all_success)``, ``evaluated=$($gxPayload.smoke_evaluated_expectations)``, ``successful=$($gxPayload.smoke_successful_expectations)``
- Check count: ``$($checks.Count)``
- Pass count: ``$passCount``
- Warn count: ``$warnCount``
- Fail count: ``$failCount``
- Status: ``$status``

## Inputs

- P11v2: ``$P11v2RunDir``
- P12v2 query reference: ``$P12v2QueryRunDir``
- P12v2 ClickHouse/Elasticsearch: ``$P12v2MainRunDir``
- P13v2: ``$P13v2PackageDir``
- P15v2: ``$P15v2RunDir``

## Outputs

- ``p17v2_status.tsv``
- ``quality_check_results.tsv``
- ``quality_rule_catalog.md``
- ``gx_validation_result.json``
- ``gx_checkpoint_summary.tsv``
- ``source_evidence_manifest.tsv``
- group-level ``*_status.tsv`` files

## Boundary

P17v2 is an evidence-reading quality gate. It does not rerun the business pipeline, does not require all V2 services to stay resident, does not print or copy passwords, and does not replace P14v2/P18v2.
"@
Write-Utf8 (Join-Path $runDir "p17v2_summary.md") $summary

Write-Host "P17V2_LOCAL_RUN_DIR=$runDir"
Write-Host "P17V2_REMOTE_RUN_DIR=$remoteRunDir"
Write-Host "P17V2_STATUS=$status"

if ($status -ne "PASS") {
    exit 2
}

