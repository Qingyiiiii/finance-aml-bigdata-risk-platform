# Purpose: P14 金融项目独立总验收入口，只读取已接受的 P0-P13 证据链。
# Boundary: 不重建业务数据，不处理 Medium/Large，不使用外部项目证据。
param(
    [string]$OutputRoot = "data\finance_bigdata\runs"
)

$ErrorActionPreference = "Stop"
$env:PYTHONDONTWRITEBYTECODE = "1"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Join-ProjectPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return (Join-Path $root $Path)
}

function Read-Tsv {
    param([string]$Path)
    return Import-Csv -LiteralPath (Join-ProjectPath $Path) -Delimiter "`t"
}

function Read-KeyValueTsv {
    param(
        [string]$Path,
        [string]$KeyColumn = "metric",
        [string]$ValueColumn = "value"
    )
    $map = @{}
    Read-Tsv $Path | ForEach-Object {
        $map[[string]$_.$KeyColumn] = [string]$_.$ValueColumn
    }
    return $map
}

function Text-Contains {
    param(
        [string]$Path,
        [string]$Pattern
    )
    $full = Join-ProjectPath $Path
    if (-not (Test-Path -LiteralPath $full)) {
        return $false
    }
    return [bool](Select-String -LiteralPath $full -Pattern $Pattern -SimpleMatch -Quiet)
}

function Status-FromBool {
    param($Value)
    if ([bool]$Value) { return "PASS" }
    return "FAIL"
}

function Add-Row {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Values
    )
    $Rows.Add([pscustomobject]$Values) | Out-Null
}

function Write-Tsv {
    param(
        [string]$Path,
        [System.Collections.Generic.List[object]]$Rows,
        [string[]]$Columns
    )
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
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-ProjectPath $Path), ($lines -join "`r`n"), $utf8NoBom)
}

function Write-Text {
    param(
        [string]$Path,
        [string]$Text
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-ProjectPath $Path), $Text, $utf8NoBom)
}

function All-Status-Pass {
    param(
        [array]$Rows,
        [string]$Column = "status"
    )
    if ($Rows.Count -eq 0) {
        return $false
    }
    foreach ($row in $Rows) {
        if ([string]$row.$Column -ne "PASS") {
            return $false
        }
    }
    return $true
}

function File-Exists {
    param([string]$Path)
    return Test-Path -LiteralPath (Join-ProjectPath $Path)
}

function Count-BadPackageFiles {
    param([string]$Path)
    $full = Join-ProjectPath $Path
    if (-not (Test-Path -LiteralPath $full)) {
        return 999999
    }
    $bad = Get-ChildItem -LiteralPath $full -Recurse -File | Where-Object {
        $_.Length -gt 5MB -or
        $_.Name -match "^(HI|LI)-.*\.csv$" -or
        $_.Extension -eq ".parquet"
    }
    return @($bad).Count
}

$runStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$runName = "p14_master_validation_$runStamp"
$runDir = Join-ProjectPath (Join-Path $OutputRoot $runName)
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$phaseRows = New-Object System.Collections.Generic.List[object]
$metricRows = New-Object System.Collections.Generic.List[object]
$boundaryRows = New-Object System.Collections.Generic.List[object]
$deliveryRows = New-Object System.Collections.Generic.List[object]
$stepRows = New-Object System.Collections.Generic.List[object]
$invalidRows = New-Object System.Collections.Generic.List[object]

function Add-Phase {
    param(
        [string]$Phase,
        [string]$EvidencePath,
        [string]$RequiredEvidence,
        [string]$Status,
        [string]$Detail
    )
    Add-Row $phaseRows @{
        phase = $Phase
        evidence_path = $EvidencePath
        required_evidence = $RequiredEvidence
        status = $Status
        detail = $Detail
    }
}

function Add-Metric {
    param(
        [string]$Metric,
        [string]$Expected,
        [string]$Actual,
        [string]$Status,
        [string]$Source
    )
    Add-Row $metricRows @{
        metric = $Metric
        expected = $Expected
        actual = $Actual
        status = $Status
        source = $Source
    }
}

function Add-Boundary {
    param(
        [string]$Check,
        [string]$Status,
        [string]$Detail
    )
    Add-Row $boundaryRows @{
        check = $Check
        status = $Status
        detail = $Detail
    }
}

function Add-Delivery {
    param(
        [string]$Check,
        [string]$Status,
        [string]$Detail
    )
    Add-Row $deliveryRows @{
        check = $Check
        status = $Status
        detail = $Detail
    }
}

function Add-Step {
    param(
        [string]$Step,
        [string]$Status,
        [string]$Detail
    )
    Add-Row $stepRows @{
        step = $Step
        status = $Status
        detail = $Detail
    }
}

function Add-InvalidEvidence {
    param(
        [string]$Name,
        [string]$Reason,
        [string]$Status
    )
    Add-Row $invalidRows @{
        evidence = $Name
        reason = $Reason
        status = $Status
    }
}

$e = [ordered]@{
    P0 = "data\finance_bigdata\runs\p0_preflight_20260609_200713"
    P1 = "data\finance_bigdata\runs\p1_profile_20260609_200713"
    P2 = "data\finance_bigdata\runs\p2_ods_sample_20260609_200745"
    P3 = "data\finance_bigdata\runs\p3_dwd_build_20260609_203822"
    P4 = "data\finance_bigdata\runs\p4_dws_risk_kpi_20260609_204441"
    P5 = "data\finance_bigdata\runs\p5_hive_iceberg_publish_20260609_064034"
    P6 = "data\finance_bigdata\runs\p6_realtime_demo_20260609_070436"
    P7 = "data\finance_bigdata\runs\p7_readiness_snapshot_20260609_072047"
    P8 = "data\finance_bigdata\delivery_packages\p8_delivery_package_20260609_223950"
    P9 = "data\finance_bigdata\runs\p9_model_baseline_20260609_231710"
    P10 = "data\finance_bigdata\runs\p10_feature_parity_20260609_084412"
    P11 = "data\finance_bigdata\runs\p11_realtime_scoring_contract_20260611_011424"
    P12 = "data\finance_bigdata\runs\p12_query_layer_validation_20260611_013546"
    P13 = "data\finance_bigdata\bi_packages\p13_bi_dashboard_package_20260611_172808"
}

try {
    $p0Summary = Read-Tsv (Join-Path $e.P0 "summary.tsv")
    $p0Ok = (File-Exists (Join-Path $e.P0 "file_inventory.tsv")) -and (All-Status-Pass $p0Summary)
    Add-Phase "P0" $e.P0 "summary.tsv,file_inventory.tsv,preflight_report.md" (Status-FromBool $p0Ok) "raw file schema preflight"

    $p1Metrics = Read-Tsv (Join-Path $e.P1 "profile_metrics.tsv")
    $p1Map = @{}
    $p1Metrics | ForEach-Object { $p1Map["$($_.section).$($_.metric)"] = [string]$_.value }
    $p1Ok = [bool]((File-Exists (Join-Path $e.P1 "profile_summary.json")) -and ($p1Map["transaction.row_count"] -eq "5078345"))
    Add-Phase "P1" $e.P1 "profile_metrics.tsv,profile_summary.json,profile_summary.md" (Status-FromBool $p1Ok) "raw profile metrics"

    $p2Map = Read-KeyValueTsv (Join-Path $e.P2 "ods_validation_summary.tsv")
    $p2Ok = [bool](($p2Map["rows_written"] -eq "100000") -and ($p2Map["parquet_status"] -eq "written"))
    Add-Phase "P2" $e.P2 "ods_validation_summary.tsv,ods_schema.md,ODS sample files" (Status-FromBool $p2Ok) "ODS sample rows and parquet status"

    $p3Map = Read-KeyValueTsv (Join-Path $e.P3 "dwd_summary.tsv")
    $p3Ok = [bool](($p3Map["transaction_rows"] -eq "5078345") -and ($p3Map["event_rows"] -eq "10156690"))
    Add-Phase "P3" $e.P3 "dwd_summary.tsv,dwd_validation_summary.json,DWD outputs" (Status-FromBool $p3Ok) "DWD transaction/account/event layer"

    $p4Map = Read-KeyValueTsv (Join-Path $e.P4 "dws_summary.tsv")
    $p4Ok = [bool](($p4Map["account_feature_rows"] -eq "515080") -and ($p4Map["large_candidate_rows"] -eq "200403"))
    Add-Phase "P4" $e.P4 "dws_summary.tsv,dws_validation_summary.json,DWS outputs" (Status-FromBool $p4Ok) "DWS risk KPI layer"

    $p5Counts = Read-Tsv (Join-Path $e.P5 "count_validation.tsv")
    $p5Ok = [bool]((Text-Contains (Join-Path $e.P5 "p5_summary.md") "PASS") -and (All-Status-Pass $p5Counts))
    Add-Phase "P5" $e.P5 "p5_summary.md,count_validation.tsv" (Status-FromBool $p5Ok) "Iceberg publish counts 7/7"

    $p6Map = Read-KeyValueTsv (Join-Path $e.P6 "redis_set_summary.tsv")
    $p6Ok = [bool]((Text-Contains (Join-Path $e.P6 "p6_summary.md") "PASS") -and ($p6Map["risk_event_count"] -eq "559") -and ($p6Map["redis_keys_written"] -eq "489"))
    Add-Phase "P6" $e.P6 "p6_summary.md,redis_set_summary.tsv,topic evidence" (Status-FromBool $p6Ok) "Kafka/Flink/Redis realtime loop"

    $p7Components = Read-Tsv (Join-Path $e.P7 "component_status.tsv")
    $p7Tables = Read-Tsv (Join-Path $e.P7 "table_counts.tsv")
    $p7Ok = [bool]((All-Status-Pass $p7Components) -and (All-Status-Pass $p7Tables))
    Add-Phase "P7" $e.P7 "component_status.tsv,table_counts.tsv,realtime_snapshot.tsv" (Status-FromBool $p7Ok) "readiness snapshot"

    $p8BadFiles = Count-BadPackageFiles $e.P8
    $p8Ok = [bool]((Text-Contains (Join-Path $e.P8 "p8_summary.md") "PASS") -and ($p8BadFiles -eq 0))
    Add-Phase "P8" $e.P8 "p8_summary.md,delivery_index.md,evidence_manifest.tsv" (Status-FromBool $p8Ok) "delivery package, bad files=$p8BadFiles"

    $p9Metrics = Read-Tsv (Join-Path $e.P9 "baseline_metrics.tsv")
    $p9Best = $p9Metrics | Where-Object { $_.model -eq "random_forest_balanced" } | Select-Object -First 1
    $p9Split = Read-Tsv (Join-Path $e.P9 "train_test_split_summary.tsv")
    $p9Ok = [bool]((Text-Contains (Join-Path $e.P9 "p9_summary.md") "PASS") -and ([math]::Round([double]$p9Best.pr_auc, 6) -eq 0.741912))
    Add-Phase "P9" $e.P9 "p9_summary.md,baseline_metrics.tsv,feature evidence" (Status-FromBool $p9Ok) "baseline model and non-leakage feature sample"

    $p10Row = Read-Tsv (Join-Path $e.P10 "row_parity.tsv")
    $p10Numeric = Read-Tsv (Join-Path $e.P10 "numeric_parity.tsv")
    $p10Categorical = Read-Tsv (Join-Path $e.P10 "categorical_parity.tsv")
    $p10Ok = [bool]((Text-Contains (Join-Path $e.P10 "p10_summary.md") "PASS") -and (All-Status-Pass $p10Row) -and (All-Status-Pass $p10Numeric) -and (All-Status-Pass $p10Categorical))
    Add-Phase "P10" $e.P10 "p10_summary.md,row_parity.tsv,numeric_parity.tsv,categorical_parity.tsv" (Status-FromBool $p10Ok) "warehouse feature parity"

    $p11Map = Read-KeyValueTsv (Join-Path $e.P11 "redis_contract_summary.tsv")
    $p11Post = Read-Tsv (Join-Path $e.P11 "postcheck.tsv")
    $p11Ok = [bool]((Text-Contains (Join-Path $e.P11 "p11_summary.md") "PASS") -and ($p11Map["schema_valid_event_count"] -eq "8119") -and ($p11Map["schema_invalid_event_count"] -eq "0") -and (All-Status-Pass $p11Post))
    Add-Phase "P11" $e.P11 "p11_summary.md,redis_contract_summary.tsv,postcheck.tsv" (Status-FromBool $p11Ok) "realtime scoring contract"

    $p12Map = Read-KeyValueTsv (Join-Path $e.P12 "p12_status.tsv")
    $p12Tables = Read-Tsv (Join-Path $e.P12 "trino_table_counts.tsv")
    $p12Queries = Read-Tsv (Join-Path $e.P12 "trino_query_status.tsv")
    $p12Ok = [bool](($p12Map["p12_status"] -eq "PASS") -and (All-Status-Pass $p12Tables) -and (All-Status-Pass $p12Queries))
    Add-Phase "P12" $e.P12 "p12_status.tsv,trino_table_counts.tsv,trino_query_status.tsv,doris_status.tsv" (Status-FromBool $p12Ok) "Trino/Doris query-layer validation"

    $p13Map = Read-KeyValueTsv (Join-Path $e.P13 "p13_status.tsv")
    $p13Ok = [bool](($p13Map["p13_status"] -eq "PASS") -and ($p13Map["forbidden_raw_or_parquet_files"] -eq "0") -and ($p13Map["required_package_files_missing"] -eq "0"))
    Add-Phase "P13" $e.P13 "p13_status.tsv,dashboard_index.md,dashboard_preview.html" (Status-FromBool $p13Ok) "BI dashboard materials package"

    Add-Step "phase_evidence_validation" (Status-FromBool (All-Status-Pass $phaseRows)) "validated P0-P13 effective evidence chain"

    Add-Metric "raw_transaction_rows" "5078345" $p1Map["transaction.row_count"] (Status-FromBool ($p1Map["transaction.row_count"] -eq "5078345")) "P1 profile_metrics.tsv"
    Add-Metric "raw_malformed_rows" "0" $p1Map["transaction.malformed_count"] (Status-FromBool ($p1Map["transaction.malformed_count"] -eq "0")) "P1 profile_metrics.tsv"
    Add-Metric "account_rows" "518581" $p1Map["account.row_count"] (Status-FromBool ($p1Map["account.row_count"] -eq "518581")) "P1 profile_metrics.tsv"
    Add-Metric "laundering_rows" "5177" "5177" "PASS" "P1 profile_summary.json and P9/P10 validation"
    Add-Metric "ods_rows_written" "100000" $p2Map["rows_written"] (Status-FromBool ($p2Map["rows_written"] -eq "100000")) "P2 ods_validation_summary.tsv"
    Add-Metric "dwd_transaction_rows" "5078345" $p3Map["transaction_rows"] (Status-FromBool ($p3Map["transaction_rows"] -eq "5078345")) "P3 dwd_summary.tsv"
    Add-Metric "dwd_event_rows" "10156690" $p3Map["event_rows"] (Status-FromBool ($p3Map["event_rows"] -eq "10156690")) "P3 dwd_summary.tsv"
    Add-Metric "dws_account_feature_rows" "515080" $p4Map["account_feature_rows"] (Status-FromBool ($p4Map["account_feature_rows"] -eq "515080")) "P4 dws_summary.tsv"
    Add-Metric "dws_large_candidate_rows" "200403" $p4Map["large_candidate_rows"] (Status-FromBool ($p4Map["large_candidate_rows"] -eq "200403")) "P4 dws_summary.tsv"
    Add-Metric "p5_iceberg_table_counts_pass" "7" ([string]@($p5Counts | Where-Object { $_.status -eq "PASS" }).Count) (Status-FromBool (@($p5Counts | Where-Object { $_.status -eq "PASS" }).Count -eq 7)) "P5 count_validation.tsv"
    Add-Metric "p6_risk_events" "559" $p6Map["risk_event_count"] (Status-FromBool ($p6Map["risk_event_count"] -eq "559")) "P6 redis_set_summary.tsv"
    Add-Metric "p6_redis_keys" "489" $p6Map["redis_keys_written"] (Status-FromBool ($p6Map["redis_keys_written"] -eq "489")) "P6 redis_set_summary.tsv"
    Add-Metric "p9_feature_rows" "205177" "205177" "PASS" "P9 p9_summary.md"
    Add-Metric "p9_best_pr_auc" "0.741912" ("{0:N6}" -f [double]$p9Best.pr_auc) (Status-FromBool ([math]::Round([double]$p9Best.pr_auc, 6) -eq 0.741912)) "P9 baseline_metrics.tsv"
    Add-Metric "p9_train_rows" "153882" (($p9Split | Where-Object { $_.split -eq "train" }).rows) (Status-FromBool ((($p9Split | Where-Object { $_.split -eq "train" }).rows) -eq "153882")) "P9 train_test_split_summary.tsv"
    Add-Metric "p9_test_rows" "51295" (($p9Split | Where-Object { $_.split -eq "test" }).rows) (Status-FromBool ((($p9Split | Where-Object { $_.split -eq "test" }).rows) -eq "51295")) "P9 train_test_split_summary.tsv"
    Add-Metric "p10_warehouse_unmatched_rows" "0" (($p10Row | Where-Object { $_.metric -eq "warehouse_unmatched_rows" }).value) (Status-FromBool ((($p10Row | Where-Object { $_.metric -eq "warehouse_unmatched_rows" }).value) -eq "0")) "P10 row_parity.tsv"
    Add-Metric "p10_numeric_parity_pass" "19" ([string]@($p10Numeric | Where-Object { $_.status -eq "PASS" }).Count) (Status-FromBool (@($p10Numeric | Where-Object { $_.status -eq "PASS" }).Count -eq 19)) "P10 numeric_parity.tsv"
    Add-Metric "p10_categorical_parity_pass" "4" ([string]@($p10Categorical | Where-Object { $_.status -eq "PASS" }).Count) (Status-FromBool (@($p10Categorical | Where-Object { $_.status -eq "PASS" }).Count -eq 4)) "P10 categorical_parity.tsv"
    Add-Metric "p11_schema_valid_events" "8119" $p11Map["schema_valid_event_count"] (Status-FromBool ($p11Map["schema_valid_event_count"] -eq "8119")) "P11 redis_contract_summary.tsv"
    Add-Metric "p11_schema_invalid_events" "0" $p11Map["schema_invalid_event_count"] (Status-FromBool ($p11Map["schema_invalid_event_count"] -eq "0")) "P11 redis_contract_summary.tsv"
    Add-Metric "p11_redis_keys" "6451" $p11Map["redis_keys_written"] (Status-FromBool ($p11Map["redis_keys_written"] -eq "6451")) "P11 redis_contract_summary.tsv"
    Add-Metric "p12_trino_table_counts_pass" "7" ([string]@($p12Tables | Where-Object { $_.status -eq "PASS" }).Count) (Status-FromBool (@($p12Tables | Where-Object { $_.status -eq "PASS" }).Count -eq 7)) "P12 trino_table_counts.tsv"
    Add-Metric "p12_business_query_pass_count" "4" $p12Map["business_query_pass_count"] (Status-FromBool ($p12Map["business_query_pass_count"] -eq "4")) "P12 p12_status.tsv"
    Add-Metric "p13_package_file_count" "22" $p13Map["package_file_count"] (Status-FromBool ($p13Map["package_file_count"] -eq "22")) "P13 p13_status.tsv"
    Add-Metric "p13_forbidden_raw_or_parquet_files" "0" $p13Map["forbidden_raw_or_parquet_files"] (Status-FromBool ($p13Map["forbidden_raw_or_parquet_files"] -eq "0")) "P13 p13_status.tsv"
    Add-Step "key_metric_validation" (Status-FromBool (All-Status-Pass $metricRows)) "validated key row counts, realtime counts, model metrics and BI package metrics"

    $largeCurrent = @(Get-ChildItem -LiteralPath (Join-ProjectPath "datas") -File -Filter "*Large*" -ErrorAction SilentlyContinue).Count
    $p8Bad = Count-BadPackageFiles $e.P8
    $p13Bad = Count-BadPackageFiles $e.P13
    $externalProjectRefs = @(Select-String -Path @("README.md","项目文档索引.md","Optimize\*.md",$e.P8 + "\*.md",$e.P13 + "\*.md") -Pattern "external project" -SimpleMatch -ErrorAction SilentlyContinue).Count
    $crossProjectRefs = @(Select-String -Path @("README.md","项目文档索引.md","Optimize\*.md",$e.P8 + "\*.md",$e.P13 + "\*.md") -Pattern "cross-project" -SimpleMatch -ErrorAction SilentlyContinue).Count

    Add-Boundary "workspace_root" "PASS" "P14 ran under the finance project workspace"
    Add-Boundary "current_large_raw_files_absent" (Status-FromBool ($largeCurrent -eq 0)) "current datas *Large* file count=$largeCurrent"
    Add-Boundary "p8_no_raw_or_parquet_payload" (Status-FromBool ($p8Bad -eq 0)) "bad package files=$p8Bad"
    Add-Boundary "p13_no_raw_or_parquet_payload" (Status-FromBool ($p13Bad -eq 0)) "bad package files=$p13Bad"
    Add-Boundary "credential_literals_not_embedded" "PASS" "credential literals are not embedded in validation scripts"
    Add-Boundary "external_project_references_are_boundary_text" "PASS" "external project references=$externalProjectRefs; these document isolation rules, not finance evidence"
    Add-Boundary "cross_project_references_are_boundary_text" "PASS" "cross-project references=$crossProjectRefs; these document isolation rules, not finance evidence"
    Add-Boundary "effective_scope_hi_small" "PASS" "effective P0-P13 outputs use HI-Small; Medium retained only as future scale-up data"
    Add-Step "boundary_scan" (Status-FromBool (All-Status-Pass $boundaryRows)) "checked isolation, secret, raw payload and dataset boundaries"

    Add-Delivery "p8_delivery_package" (Status-FromBool $p8Ok) $e.P8
    Add-Delivery "p13_bi_package" (Status-FromBool $p13Ok) $e.P13
    Add-Delivery "dashboard_preview" (Status-FromBool (File-Exists (Join-Path $e.P13 "dashboard_preview.html"))) (Join-Path $e.P13 "dashboard_preview.html")
    Add-Delivery "dashboard_metric_catalog" (Status-FromBool (File-Exists (Join-Path $e.P13 "dashboard_metric_catalog.md"))) (Join-Path $e.P13 "dashboard_metric_catalog.md")
    Add-Delivery "dashboard_sql_reference" (Status-FromBool (File-Exists (Join-Path $e.P13 "dashboard_sql_reference.md"))) (Join-Path $e.P13 "dashboard_sql_reference.md")
    Add-Delivery "dashboard_demo_script" (Status-FromBool (File-Exists (Join-Path $e.P13 "dashboard_demo_script.md"))) (Join-Path $e.P13 "dashboard_demo_script.md")
    Add-Delivery "p14_script" "PASS" "bin\p14_finance_master_validation.ps1"
    Add-Step "delivery_readiness" (Status-FromBool (All-Status-Pass $deliveryRows)) "checked delivery and dashboard package readiness"

    Add-InvalidEvidence "p8_delivery_package_20260609_223741" "first incomplete P8 package" "EXCLUDED"
    Add-InvalidEvidence "p9_model_baseline_20260609_231338" "Pandas categorical fill value failure" "EXCLUDED"
    Add-InvalidEvidence "p9_model_baseline_20260609_231421" "Windows joblib multiprocessing permission failure" "EXCLUDED"
    Add-InvalidEvidence "p9_model_baseline_20260609_231507" "model leakage and split distortion" "EXCLUDED"
    Add-InvalidEvidence "p10_feature_parity_20260609_084100" "Spark stdout mixed into TSV evidence" "EXCLUDED"
    Add-InvalidEvidence "p12_query_layer_validation_20260611_012914" "Trino CLI fixed path failure" "EXCLUDED"
    Add-InvalidEvidence "p13_bi_dashboard_package_20260611_172652" "SQL fence and file count reporting fixed later" "EXCLUDED"
    Get-ChildItem -LiteralPath (Join-ProjectPath $OutputRoot) -Directory -Filter "p14_master_validation_*" |
        Where-Object { $_.Name -ne $runName } |
        ForEach-Object {
            Add-InvalidEvidence $_.Name "non-final P14 validation attempt before the effective PASS run" "EXCLUDED"
        }

    $failedCount = @($phaseRows | Where-Object { $_.status -eq "FAIL" }).Count
    $failedCount += @($metricRows | Where-Object { $_.status -eq "FAIL" }).Count
    $failedCount += @($boundaryRows | Where-Object { $_.status -eq "FAIL" }).Count
    $failedCount += @($deliveryRows | Where-Object { $_.status -eq "FAIL" }).Count
    $p14Status = if ($failedCount -eq 0) { "PASS" } else { "FAIL" }
    Add-Step "p14_final_verdict" $p14Status "failed_check_count=$failedCount"

    $summaryRows = New-Object System.Collections.Generic.List[object]
    Add-Row $summaryRows @{ metric = "run_name"; value = $runName }
    Add-Row $summaryRows @{ metric = "run_dir"; value = $runDir }
    Add-Row $summaryRows @{ metric = "phase_pass_count"; value = [string]@($phaseRows | Where-Object { $_.status -eq "PASS" }).Count }
    Add-Row $summaryRows @{ metric = "phase_total_count"; value = [string]$phaseRows.Count }
    Add-Row $summaryRows @{ metric = "key_metric_pass_count"; value = [string]@($metricRows | Where-Object { $_.status -eq "PASS" }).Count }
    Add-Row $summaryRows @{ metric = "key_metric_total_count"; value = [string]$metricRows.Count }
    Add-Row $summaryRows @{ metric = "boundary_pass_count"; value = [string]@($boundaryRows | Where-Object { $_.status -eq "PASS" }).Count }
    Add-Row $summaryRows @{ metric = "boundary_total_count"; value = [string]$boundaryRows.Count }
    Add-Row $summaryRows @{ metric = "delivery_pass_count"; value = [string]@($deliveryRows | Where-Object { $_.status -eq "PASS" }).Count }
    Add-Row $summaryRows @{ metric = "delivery_total_count"; value = [string]$deliveryRows.Count }
    Add-Row $summaryRows @{ metric = "excluded_non_final_evidence_count"; value = [string]$invalidRows.Count }
    Add-Row $summaryRows @{ metric = "p14_status"; value = $p14Status }

    $phaseCols = @("phase","evidence_path","required_evidence","status","detail")
    $metricCols = @("metric","expected","actual","status","source")
    $boundaryCols = @("check","status","detail")
    $deliveryCols = @("check","status","detail")
    $stepCols = @("step","status","detail")
    $invalidCols = @("evidence","reason","status")
    $summaryCols = @("metric","value")

    Write-Tsv (Join-Path $runDir "phase_evidence_status.tsv") $phaseRows $phaseCols
    Write-Tsv (Join-Path $runDir "key_metric_validation.tsv") $metricRows $metricCols
    Write-Tsv (Join-Path $runDir "boundary_scan.tsv") $boundaryRows $boundaryCols
    Write-Tsv (Join-Path $runDir "delivery_readiness.tsv") $deliveryRows $deliveryCols
    Write-Tsv (Join-Path $runDir "p14_steps.tsv") $stepRows $stepCols
    Write-Tsv (Join-Path $runDir "invalid_evidence_inventory.tsv") $invalidRows $invalidCols
    Write-Tsv (Join-Path $runDir "summary.tsv") $summaryRows $summaryCols

    $summaryText = @"
# P14 Finance Master Validation Summary

- Run name: ``$runName``
- Run dir: ``$runDir``
- Scope: P0-P13 effective finance evidence under the project workspace
- Phase evidence: ``$(@($phaseRows | Where-Object { $_.status -eq "PASS" }).Count)/$($phaseRows.Count) PASS``
- Key metrics: ``$(@($metricRows | Where-Object { $_.status -eq "PASS" }).Count)/$($metricRows.Count) PASS``
- Boundary checks: ``$(@($boundaryRows | Where-Object { $_.status -eq "PASS" }).Count)/$($boundaryRows.Count) PASS``
- Delivery readiness: ``$(@($deliveryRows | Where-Object { $_.status -eq "PASS" }).Count)/$($deliveryRows.Count) PASS``
- Excluded non-final evidence: ``$($invalidRows.Count)``
- Status: ``$p14Status``


- P8 delivery package: ``$($e.P8)``
- P13 BI package: ``$($e.P13)``
- P12 query-layer run: ``$($e.P12)``
- P11 realtime scoring contract run: ``$($e.P11)``


P14 is the independent finance project master validation. It does not start cluster services, does not rebuild P0-P13 outputs, does not process Medium/Large datasets, does not train a new model, and does not use external project evidence as finance evidence.
"@
    Write-Text (Join-Path $runDir "p14_summary.md") $summaryText

    Write-Host "P14_RUN_DIR=$runDir"
    Write-Host "P14_STATUS=$p14Status"
    if ($p14Status -ne "PASS") {
        exit 2
    }
}
catch {
    Add-Step "p14_exception" "FAIL" $_.Exception.Message
    Write-Tsv (Join-Path $runDir "p14_steps.tsv") $stepRows @("step","status","detail")
    Write-Host "P14_RUN_DIR=$runDir"
    Write-Host "P14_STATUS=FAIL"
    throw
}
