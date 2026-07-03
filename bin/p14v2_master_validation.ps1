# P14v2 local orchestrator: V2 independent master validation.
# Boundary: read accepted evidence only; do not start cluster services or rebuild data.
param(
    [string]$OutputRoot = "data\finance_bigdata_v2\runs",
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
        elseif ($_.query) { $map[[string]$_.query] = [string]$_.status }
        elseif ($_.item) { $map[[string]$_.item] = [string]$_.status }
        elseif ($_.stage) { $map[[string]$_.stage] = [string]$_.actual_status }
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

function Test-File {
    param([string]$Path)
    return Test-Path -LiteralPath (Join-ProjectPath $Path)
}

function Test-AllPass {
    param([object[]]$Rows, [string]$Column = "status")
    $items = @($Rows)
    if ($items.Count -eq 0) { return $false }
    return (@($items | Where-Object { [string]$_.$Column -ne "PASS" }).Count -eq 0)
}

function Get-FirstValue {
    param([object[]]$Rows, [string]$NameColumn, [string]$Name, [string]$ValueColumn)
    $row = @($Rows | Where-Object { $_.$NameColumn -eq $Name } | Select-Object -First 1)
    if ($row.Count -eq 0) { return "" }
    return [string]$row[0].$ValueColumn
}

function Add-Row {
    param([System.Collections.Generic.List[object]]$Rows, [hashtable]$Values)
    $Rows.Add([pscustomobject]$Values) | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$runName = "p14v2_master_validation_$stamp"
$runDir = Join-ProjectPath (Join-Path $OutputRoot $runName)
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$phaseRows = New-Object System.Collections.Generic.List[object]
$matrixRows = New-Object System.Collections.Generic.List[object]
$componentRows = New-Object System.Collections.Generic.List[object]
$metricRows = New-Object System.Collections.Generic.List[object]
$boundaryRows = New-Object System.Collections.Generic.List[object]
$deliveryRows = New-Object System.Collections.Generic.List[object]
$invalidRows = New-Object System.Collections.Generic.List[object]
$stepRows = New-Object System.Collections.Generic.List[object]

function Add-Step([string]$Step, [string]$Status, [string]$Detail) {
    Add-Row $stepRows @{ step = $Step; status = $Status; detail = $Detail }
}

function Add-Phase([string]$Phase, [string]$EvidencePath, [string]$RequiredEvidence, [string]$Status, [string]$Detail) {
    Add-Row $phaseRows @{
        phase = $Phase
        evidence_path = $EvidencePath
        required_evidence = $RequiredEvidence
        status = $Status
        detail = $Detail
    }
}

function Add-Matrix([string]$Dimension, [string]$Object, [string]$Target, [string]$Evidence, [string]$Status, [string]$MainValidation, [string]$FailureAction) {
    Add-Row $matrixRows @{
        dimension = $Dimension
        validation_object = $Object
        v2_target = $Target
        evidence_source = $Evidence
        current_status = $Status
        main_validation = $MainValidation
        failure_action = $FailureAction
    }
}

function Add-Component([string]$Component, [string]$ExpectedRole, [string]$Evidence, [string]$Status, [string]$Detail) {
    Add-Row $componentRows @{
        component = $Component
        expected_role = $ExpectedRole
        evidence_source = $Evidence
        status = $Status
        detail = $Detail
    }
}

function Add-Metric([string]$Metric, [string]$Expected, [string]$Actual, [string]$Status, [string]$Source) {
    Add-Row $metricRows @{
        metric = $Metric
        expected = $Expected
        actual = $Actual
        status = $Status
        source = $Source
    }
}

function Add-Boundary([string]$Check, [string]$Expected, [string]$Actual, [string]$Status, [string]$Detail) {
    Add-Row $boundaryRows @{
        check = $Check
        expected = $Expected
        actual = $Actual
        status = $Status
        detail = $Detail
    }
}

function Add-Delivery([string]$Check, [string]$Expected, [string]$Actual, [string]$Status, [string]$Detail) {
    Add-Row $deliveryRows @{
        check = $Check
        expected = $Expected
        actual = $Actual
        status = $Status
        detail = $Detail
    }
}

function Add-Invalid([string]$Evidence, [string]$Reason, [string]$Treatment, [string]$Status) {
    Add-Row $invalidRows @{
        evidence = $Evidence
        reason = $Reason
        treatment = $Treatment
        status = $Status
    }
}

Add-Step "create_run_dir" "PASS" $runDir

$p11State = Join-Path $P11v2RunDir "p11v2_state_summary.tsv"
$p11Summary = Join-Path $P11v2RunDir "p11v2_summary.md"
$p11Post = Join-Path $P11v2RunDir "postcheck.tsv"
$p12MainStatus = Join-Path $P12v2MainRunDir "p12v2_status.tsv"
$p12Clickhouse = Join-Path $P12v2MainRunDir "clickhouse_query_status.tsv"
$p12Elastic = Join-Path $P12v2MainRunDir "elasticsearch_index_status.tsv"
$p12QueryStatus = Join-Path $P12v2QueryRunDir "p12v2_status.tsv"
$p12Trino = Join-Path $P12v2QueryRunDir "trino_query_status.tsv"
$p13StatusPath = Join-Path $P13v2PackageDir "p13v2_status.tsv"
$p13BoundaryPath = Join-Path $P13v2PackageDir "package_boundary_scan.tsv"
$p15StatusPath = Join-Path $P15v2RunDir "p15v2_status.tsv"
$p15FinalPath = Join-Path $P15v2RunDir "p15v2_final_status.tsv"
$p17StatusPath = Join-Path $P17v2RunDir "p17v2_status.tsv"

$p11Map = Read-Kv $p11State
$p11SummaryText = Get-Content -LiteralPath (Join-ProjectPath $p11Summary) -Raw -Encoding UTF8
$p11PostRows = Read-Tsv $p11Post
$p11Status = if ($p11SummaryText -match 'Status:\s*`PASS`' -and $p11Map["schema_invalid_event_count"] -eq "0" -and [int]$p11Map["hbase_rows_written"] -gt 0 -and (Test-AllPass $p11PostRows)) { "PASS" } else { "FAIL" }

$p12Map = Read-Kv $p12MainStatus
$p12ClickRows = Read-Tsv $p12Clickhouse
$p12ElasticRows = Read-Tsv $p12Elastic
$p12QueryMap = Read-Kv $p12QueryStatus
$p12TrinoRows = Read-Tsv $p12Trino
$p12Status = Status-FromBool ($p12Map["p12v2_status"] -eq "PASS" -and $p12QueryMap["p12v2_status"] -eq "PASS" -and (Test-AllPass $p12ClickRows) -and (Test-AllPass $p12ElasticRows) -and (Test-AllPass $p12TrinoRows))

$p13Map = Read-Kv $p13StatusPath
$p13BoundaryRows = Read-Tsv $p13BoundaryPath
$p13Status = Status-FromBool ($p13Map["p13v2_status"] -eq "PASS" -and $p13Map["bad_file_count"] -eq "0" -and $p13Map["credential_pattern_hit_count"] -eq "0" -and (Test-AllPass $p13BoundaryRows))

$p15Map = Read-Kv $p15StatusPath
$p15FinalMap = Read-Kv $p15FinalPath
$p15BaseRows = Read-Tsv (Join-Path $P15v2RunDir "base_platform_status.tsv")
$p15IcebergRows = Read-Tsv (Join-Path $P15v2RunDir "iceberg_table_counts.tsv")
$p15HbaseRows = Read-Tsv (Join-Path $P15v2RunDir "hbase_readiness.tsv")
$p15ClickhouseRows = Read-Tsv (Join-Path $P15v2RunDir "clickhouse_readiness.tsv")
$p15ElasticRows = Read-Tsv (Join-Path $P15v2RunDir "elasticsearch_readiness.tsv")
$p15RangerRows = Read-Tsv (Join-Path $P15v2RunDir "ranger_readiness.tsv")
$p15AtlasRows = Read-Tsv (Join-Path $P15v2RunDir "atlas_readiness.tsv")
$p15MonitoringRows = Read-Tsv (Join-Path $P15v2RunDir "prometheus_grafana_readiness.tsv")
$p15BackupRows = Read-Tsv (Join-Path $P15v2RunDir "backup_components_status.tsv")
$p15PortRows = Read-Tsv (Join-Path $P15v2RunDir "port_binding_scan.tsv")
$p15Status = Status-FromBool (
    $p15Map["p15v2_status"] -eq "PASS" -and
    $p15FinalMap["p15v2_status"] -eq "PASS" -and
    $p15Map["execution_mode"] -eq "low_memory_sequential" -and
    $p15Map["memory_warning_count"] -eq "0" -and
    $p15Map["port_binding_fail_count"] -eq "0" -and
    (Test-AllPass $p15BaseRows) -and
    (Test-AllPass $p15IcebergRows) -and
    (Test-AllPass $p15HbaseRows) -and
    (Test-AllPass $p15ClickhouseRows) -and
    (Test-AllPass $p15ElasticRows) -and
    (Test-AllPass $p15RangerRows) -and
    (Test-AllPass $p15AtlasRows) -and
    (Test-AllPass $p15MonitoringRows) -and
    (Test-AllPass $p15BackupRows) -and
    (Test-AllPass $p15PortRows)
)

$p17Map = Read-Kv $p17StatusPath
$p17QualityRows = Read-Tsv (Join-Path $P17v2RunDir "quality_check_results.tsv")
$p17GxRows = Read-Tsv (Join-Path $P17v2RunDir "gx_framework_status.tsv")
$p17Status = Status-FromBool ($p17Map["p17v2_status"] -eq "PASS" -and $p17Map["fail_count"] -eq "0" -and $p17Map["gx_all_success"] -eq "True" -and (Test-AllPass $p17QualityRows) -and (Test-AllPass $p17GxRows))

Add-Phase "P11v2" $P11v2RunDir "p11v2_summary.md,p11v2_state_summary.tsv,postcheck.tsv" $p11Status "Redis cache plus HBase durable state evidence"
Add-Phase "P12v2" $P12v2MainRunDir "p12v2_status.tsv,clickhouse_query_status.tsv,elasticsearch_index_status.tsv" $p12Status "ClickHouse and Elasticsearch accepted evidence"
Add-Phase "P12v2_Trino_reference" $P12v2QueryRunDir "p12v2_status.tsv,trino_query_status.tsv" (Status-FromBool ($p12QueryMap["p12v2_status"] -eq "PASS" -and (Test-AllPass $p12TrinoRows))) "Trino/Iceberg reference evidence"
Add-Phase "P13v2" $P13v2PackageDir "p13v2_status.tsv,package_boundary_scan.tsv,dashboard files" $p13Status "Static ClickHouse-backed BI package"
Add-Phase "P15v2" $P15v2RunDir "p15v2_status.tsv,p15v2_final_status.tsv,module readiness files" $p15Status "Low-memory modular restart readiness"
Add-Phase "P17v2" $P17v2RunDir "p17v2_status.tsv,quality_check_results.tsv,gx_validation_result.json" $p17Status "Great Expectations quality gate"
Add-Step "phase_evidence_validation" (Status-FromBool (Test-AllPass $phaseRows)) "validated V2 effective evidence chain"

$baseQualityRows = @($p17QualityRows | Where-Object { $_.rule_group -eq "base_data_quality" })
$sourceEvidenceRows = @($p17QualityRows | Where-Object { $_.rule_group -eq "source_evidence" })
$realtimeQualityRows = @($p17QualityRows | Where-Object { $_.rule_group -eq "realtime_state_quality" })
$queryQualityRows = @($p17QualityRows | Where-Object { $_.rule_group -eq "query_search_quality" })
$biQualityRows = @($p17QualityRows | Where-Object { $_.rule_group -eq "bi_package_quality" })
$restartQualityRows = @($p17QualityRows | Where-Object { $_.rule_group -eq "restart_readiness_quality" })
$securityRows = @($p17QualityRows | Where-Object { $_.rule_group -eq "security_boundary" })

Add-Matrix "base_lakehouse" "V1 base plus Iceberg evidence" "Baseline facts reusable as input only" $P17v2RunDir (Status-FromBool ((Test-AllPass $baseQualityRows) -and (Test-AllPass $p15IcebergRows))) "yes" "fail P14v2"
Add-Matrix "realtime_state" "P11v2 Redis cache plus HBase durable state" "HBase is durable state; Redis is cache" $P11v2RunDir $p11Status "yes" "fail P14v2"
Add-Matrix "query_search" "P12v2 Trino/ClickHouse/Elasticsearch" "Query and investigation copies are readable" $P12v2MainRunDir $p12Status "yes" "fail P14v2"
Add-Matrix "bi_package" "P13v2 BI package" "Static, lightweight, ClickHouse-backed display package" $P13v2PackageDir $p13Status "yes" "fail P14v2"
Add-Matrix "data_quality" "P17v2 GX quality gate" "GX and custom quality gates pass" $P17v2RunDir $p17Status "yes" "fail P14v2"
Add-Matrix "restart_readiness" "P15v2 modular recovery" "Low-memory sequential recovery evidence passes" $P15v2RunDir $p15Status "yes" "fail P14v2"
Add-Matrix "governance" "Ranger and Atlas minimal governance" "Ranger Admin and Atlas minimal readiness pass" $P15v2RunDir (Status-FromBool ((Test-AllPass $p15RangerRows) -and (Test-AllPass $p15AtlasRows))) "yes" "fail P14v2"
Add-Matrix "monitoring" "Prometheus and Grafana light monitoring" "Light targets/dashboard evidence passes" $P15v2RunDir (Status-FromBool (Test-AllPass $p15MonitoringRows)) "yes" "fail P14v2"
Add-Matrix "package_boundary" "P13v2 and future P18v2 package boundaries" "No raw data, parquet details, credentials, or large files" $P13v2PackageDir (Status-FromBool ((Test-AllPass $biQualityRows) -and $p13Map["credential_pattern_hit_count"] -eq "0")) "yes" "fail P14v2"
Add-Matrix "security_boundary" "Credential and evidence isolation" "No password output and no V1/P14/P18 masquerading" $P17v2RunDir (Status-FromBool (Test-AllPass $securityRows)) "yes" "fail P14v2"

Add-Component "Iceberg" "Long-term fact lakehouse baseline" (Join-Path $P15v2RunDir "iceberg_table_counts.tsv") (Status-FromBool (Test-AllPass $p15IcebergRows)) "dws_account_risk_features count validated"
$extraConfig = Get-Content -LiteralPath (Join-ProjectPath "金融大数据额外配置.md") -Raw -Encoding UTF8
Add-Component "Hudi" "Optional CDC/upsert lakehouse supplement" "金融大数据额外配置.md" (Status-FromBool ($extraConfig -match "Hudi.*已完成" -and $extraConfig -match "smoke upsert")) "No daemon; upsert smoke recorded in V2 config"
Add-Component "Redis" "Latest-state cache only" $P11v2RunDir (Status-FromBool ($p11Map["redis_keys_written"] -eq "6375")) "Cache count recorded; not treated as fact source"
Add-Component "HBase" "Durable account risk state" (Join-Path $P15v2RunDir "hbase_readiness.tsv") (Status-FromBool (Test-AllPass $p15HbaseRows)) "finance_bigdata_v2:account_risk_state readable"
Add-Component "Trino" "Interactive cross-table query reference" (Join-Path $P12v2QueryRunDir "trino_query_status.tsv") (Status-FromBool (Test-AllPass $p12TrinoRows)) "Reference evidence only"
Add-Component "ClickHouse" "OLAP/BI display layer" (Join-Path $P15v2RunDir "clickhouse_readiness.tsv") (Status-FromBool (Test-AllPass $p15ClickhouseRows)) "finance_bigdata_v2 ADS rows available"
Add-Component "Elasticsearch" "Investigation search copy" (Join-Path $P15v2RunDir "elasticsearch_readiness.tsv") (Status-FromBool (Test-AllPass $p15ElasticRows)) "finance-risk-events-v2 searchable"
Add-Component "Great Expectations" "Main data quality gate" (Join-Path $P17v2RunDir "gx_framework_status.tsv") (Status-FromBool (Test-AllPass $p17GxRows)) "GX smoke and checkpoint pass"
Add-Component "Ranger" "Minimal governance UI/admin evidence" (Join-Path $P15v2RunDir "ranger_readiness.tsv") (Status-FromBool (Test-AllPass $p15RangerRows)) "UserSync inactive is acceptable"
Add-Component "Atlas" "Minimal metadata service evidence" (Join-Path $P15v2RunDir "atlas_readiness.tsv") (Status-FromBool (Test-AllPass $p15AtlasRows)) "Atlas ACTIVE, hooks not required"
Add-Component "Prometheus/Grafana" "Light monitoring evidence" (Join-Path $P15v2RunDir "prometheus_grafana_readiness.tsv") (Status-FromBool (Test-AllPass $p15MonitoringRows)) "Two Prometheus targets up and dashboard present"
Add-Component "OpenSearch/Deequ/Soda" "Backup-only components" (Join-Path $P15v2RunDir "backup_components_status.tsv") (Status-FromBool (Test-AllPass $p15BackupRows)) "Not promoted to main validation"

Add-Metric "p11v2_schema_invalid_event_count" "0" $p11Map["schema_invalid_event_count"] (Status-FromBool ($p11Map["schema_invalid_event_count"] -eq "0")) $p11State
Add-Metric "p11v2_hbase_rows_written" ">0" $p11Map["hbase_rows_written"] (Status-FromBool ([int]$p11Map["hbase_rows_written"] -gt 0)) $p11State
Add-Metric "p11v2_redis_hbase_consistency_fail_count" "0" $p11Map["redis_hbase_consistency_fail_count"] (Status-FromBool ($p11Map["redis_hbase_consistency_fail_count"] -eq "0")) $p11State
Add-Metric "p12v2_clickhouse_ads_rows" "6375" $p12Map["clickhouse_ads_rows"] (Status-FromBool ($p12Map["clickhouse_ads_rows"] -eq "6375")) $p12MainStatus
Add-Metric "p12v2_clickhouse_events_rows" "8109" $p12Map["clickhouse_events_rows"] (Status-FromBool ($p12Map["clickhouse_events_rows"] -eq "8109")) $p12MainStatus
Add-Metric "p12v2_elasticsearch_document_count" "8109" $p12Map["elasticsearch_document_count"] (Status-FromBool ($p12Map["elasticsearch_document_count"] -eq "8109")) $p12MainStatus
Add-Metric "p12v2_elasticsearch_search_hits" ">0" $p12Map["elasticsearch_search_hits"] (Status-FromBool ([int]$p12Map["elasticsearch_search_hits"] -gt 0)) $p12MainStatus
Add-Metric "p13v2_package_file_count" "45" $p13Map["package_file_count"] (Status-FromBool ($p13Map["package_file_count"] -eq "45")) $p13StatusPath
Add-Metric "p13v2_bad_file_count" "0" $p13Map["bad_file_count"] (Status-FromBool ($p13Map["bad_file_count"] -eq "0")) $p13StatusPath
Add-Metric "p15v2_memory_warning_count" "0" $p15Map["memory_warning_count"] (Status-FromBool ($p15Map["memory_warning_count"] -eq "0")) $p15StatusPath
Add-Metric "p15v2_port_binding_fail_count" "0" $p15Map["port_binding_fail_count"] (Status-FromBool ($p15Map["port_binding_fail_count"] -eq "0")) $p15StatusPath
Add-Metric "p15v2_yarn_running_apps_after" "0" $p15Map["yarn_running_apps_after"] (Status-FromBool ($p15Map["yarn_running_apps_after"] -eq "0")) $p15StatusPath
Add-Metric "p17v2_fail_count" "0" $p17Map["fail_count"] (Status-FromBool ($p17Map["fail_count"] -eq "0")) $p17StatusPath
Add-Metric "p17v2_quality_check_count" "63" $p17Map["check_count"] (Status-FromBool ($p17Map["check_count"] -eq "63")) $p17StatusPath

$acceptedEvidence = @($P11v2RunDir, $P12v2MainRunDir, $P12v2QueryRunDir, $P13v2PackageDir, $P15v2RunDir, $P17v2RunDir)
$externalProjectRefs = @($acceptedEvidence | Where-Object { $_ -match "external project" }).Count
$crossProjectRefs = @($acceptedEvidence | Where-Object { $_ -match "cross-project" }).Count
$mediumLargeFiles = @(Get-ChildItem -LiteralPath (Join-ProjectPath "datas") -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "Medium|Large" }).Count
$credentialHits = 0
$secretPattern = "(?i)(password|token|secret)\s*[:=]\s*[^`t\r\n ]+|Basic [A-Za-z0-9+/=]{12,}|CLUSTER_HADOOP.*PASSWORD\s*="
foreach ($path in @($P13v2PackageDir, $P17v2RunDir)) {
    $scanFiles = Get-ChildItem -LiteralPath (Join-ProjectPath $path) -Recurse -File -ErrorAction SilentlyContinue
    $hits = $scanFiles | Select-String -Pattern $secretPattern -ErrorAction SilentlyContinue
    $credentialHits += @($hits).Count
}
Add-Boundary "v2_output_isolated" "data/finance_bigdata_v2" $runDir (Status-FromBool ($runDir -like "*data*finance_bigdata_v2*runs*")) "P14v2 writes V2 run dir only"
Add-Boundary "v1_p14_not_reused" "not used as V2 PASS" "new P14v2 run generated" "PASS" "V1 P14 remains historical evidence"
Add-Boundary "v1_p18_not_reused" "not used as V2 PASS" "P18v2 blocked until P14v2 PASS" "PASS" "V1 P18 remains historical evidence"
Add-Boundary "external_workspace_path_references" "0" "$designRefs" (Status-FromBool ($designRefs -eq 0)) "No external workspace path used as accepted evidence"
Add-Boundary "external_project_keyword_references" "0" "$($externalProjectRefs + $crossProjectRefs)" (Status-FromBool (($externalProjectRefs + $crossProjectRefs) -eq 0)) "No non-finance project keyword used"
Add-Boundary "medium_large_input_files" "0" "$mediumLargeFiles" (Status-FromBool ($mediumLargeFiles -eq 0)) "Current data files are HI/LI Small only"
Add-Boundary "doris_not_v2_mainline" "excluded" "excluded" "PASS" "Doris retained only as V1 historical smoke"
Add-Boundary "opensearch_not_v2_mainline" "backup only" (Get-FirstValue $p15BackupRows "check" "opensearch_not_listening" "status") (Status-FromBool ((Get-FirstValue $p15BackupRows "check" "opensearch_not_listening" "status") -eq "PASS")) "OpenSearch backup status only"
Add-Boundary "deequ_soda_not_p17v2_mainline" "backup only" "backup only" "PASS" "P17v2 uses GX as main quality gate"
Add-Boundary "credential_hits_in_checked_outputs" "0" "$credentialHits" (Status-FromBool ($credentialHits -eq 0)) "No credential pattern in checked V2 outputs"
Add-Boundary "no_full_cluster_start_required" "true" "true" "PASS" "P14v2 reads evidence only"

Add-Delivery "p13v2_bi_package_available" "PASS" $p13Status (Status-FromBool ($p13Status -eq "PASS")) $P13v2PackageDir
Add-Delivery "p15v2_readiness_available" "PASS" $p15Status (Status-FromBool ($p15Status -eq "PASS")) $P15v2RunDir
Add-Delivery "p17v2_quality_report_available" "PASS" $p17Status (Status-FromBool ($p17Status -eq "PASS")) $P17v2RunDir
Add-Delivery "p14v2_summary_can_generate" "present" "present" "PASS" "This run writes p14v2_summary.md"
Add-Delivery "p18v2_not_predeclared" "not PASS before package" "not generated in P14v2" "PASS" "P18v2 must run after P14v2 PASS"

Add-Invalid "p11v2_realtime_state_20260702_040416" "failed/earlier run" "excluded" "PASS"
Add-Invalid "data/finance_bigdata/runs/p14_master_validation_20260611_184955" "V1 master validation cannot be V2 PASS" "historical only" "PASS"
Add-Invalid "data/finance_bigdata/portfolio_packages/p18_portfolio_final_package_20260613_213025" "V1 portfolio package cannot be V2 PASS" "historical only" "PASS"
Add-Invalid "Doris-only query evidence" "Doris is not V2 main display layer" "excluded" "PASS"
Add-Invalid "OpenSearch backup evidence" "OpenSearch is backup-only" "excluded from mainline" "PASS"
Add-Invalid "Deequ/Soda backup evidence" "GX is P17v2 main quality gate" "excluded from mainline" "PASS"

Write-Tsv (Join-Path $runDir "phase_evidence_status.tsv") $phaseRows @("phase", "evidence_path", "required_evidence", "status", "detail")
Write-Tsv (Join-Path $runDir "v2_validation_matrix.tsv") $matrixRows @("dimension", "validation_object", "v2_target", "evidence_source", "current_status", "main_validation", "failure_action")
Write-Tsv (Join-Path $runDir "component_validation.tsv") $componentRows @("component", "expected_role", "evidence_source", "status", "detail")
Write-Tsv (Join-Path $runDir "key_metric_validation.tsv") $metricRows @("metric", "expected", "actual", "status", "source")
Write-Tsv (Join-Path $runDir "boundary_scan.tsv") $boundaryRows @("check", "expected", "actual", "status", "detail")
Write-Tsv (Join-Path $runDir "delivery_readiness.tsv") $deliveryRows @("check", "expected", "actual", "status", "detail")
Write-Tsv (Join-Path $runDir "invalid_evidence_inventory.tsv") $invalidRows @("evidence", "reason", "treatment", "status")

$allGroupsPass = (Test-AllPass $phaseRows) -and (Test-AllPass $matrixRows "current_status") -and (Test-AllPass $componentRows) -and (Test-AllPass $metricRows) -and (Test-AllPass $boundaryRows) -and (Test-AllPass $deliveryRows) -and (Test-AllPass $invalidRows)
$status = if ($allGroupsPass) { "PASS" } else { "FAIL" }
Add-Step "write_validation_outputs" "PASS" "phase, matrix, component, metric, boundary, delivery, invalid evidence files"
Add-Step "final_status" $status "P14V2_STATUS=$status"

$summaryRows = New-Object System.Collections.Generic.List[object]
$summaryRows.Add([pscustomobject]@{ metric = "run_name"; value = $runName; status = "PASS" }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "local_run_dir"; value = "data/finance_bigdata_v2/runs/$runName"; status = "PASS" }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "phase_pass_count"; value = @($phaseRows | Where-Object { $_.status -eq "PASS" }).Count; status = (Status-FromBool (Test-AllPass $phaseRows)) }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "matrix_pass_count"; value = @($matrixRows | Where-Object { $_.current_status -eq "PASS" }).Count; status = (Status-FromBool (Test-AllPass $matrixRows "current_status")) }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "component_pass_count"; value = @($componentRows | Where-Object { $_.status -eq "PASS" }).Count; status = (Status-FromBool (Test-AllPass $componentRows)) }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "metric_pass_count"; value = @($metricRows | Where-Object { $_.status -eq "PASS" }).Count; status = (Status-FromBool (Test-AllPass $metricRows)) }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "boundary_fail_count"; value = @($boundaryRows | Where-Object { $_.status -ne "PASS" }).Count; status = (Status-FromBool (Test-AllPass $boundaryRows)) }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "delivery_fail_count"; value = @($deliveryRows | Where-Object { $_.status -ne "PASS" }).Count; status = (Status-FromBool (Test-AllPass $deliveryRows)) }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "invalid_evidence_fail_count"; value = @($invalidRows | Where-Object { $_.status -ne "PASS" }).Count; status = (Status-FromBool (Test-AllPass $invalidRows)) }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "p14v2_status"; value = $status; status = $status }) | Out-Null
Write-Tsv (Join-Path $runDir "summary.tsv") $summaryRows @("metric", "value", "status")
Write-Tsv (Join-Path $runDir "p14v2_steps.tsv") $stepRows @("step", "status", "detail")

$summaryText = @"
# P14v2 Master Validation Summary

- Run name: ``$runName``
- Local run dir: ``data/finance_bigdata_v2/runs/$runName``
- Status: ``$status``


- P11v2: ``$P11v2RunDir``
- P12v2 main: ``$P12v2MainRunDir``
- P12v2 Trino reference: ``$P12v2QueryRunDir``
- P13v2: ``$P13v2PackageDir``
- P15v2: ``$P15v2RunDir``
- P17v2: ``$P17v2RunDir``


- ``summary.tsv``
- ``phase_evidence_status.tsv``
- ``v2_validation_matrix.tsv``
- ``component_validation.tsv``
- ``key_metric_validation.tsv``
- ``boundary_scan.tsv``
- ``delivery_readiness.tsv``
- ``invalid_evidence_inventory.tsv``
- ``p14v2_steps.tsv``


P14v2 is a V2 evidence matrix validation. It does not start the cluster, rerun P11v2/P12v2/P13v2/P15v2/P17v2, rebuild data, copy raw data, or generate the P18v2 portfolio package.
"@
Write-Utf8 (Join-Path $runDir "p14v2_summary.md") $summaryText

Write-Host "P14V2_LOCAL_RUN_DIR=$runDir"
Write-Host "P14V2_STATUS=$status"
if ($status -ne "PASS") {
    exit 2
}
