param(
    [string]$PasswordFile = "PRIVATE_CREDENTIALS_ENV"
)

$ErrorActionPreference = "Stop"
$path = Resolve-Path -LiteralPath $PasswordFile
$content = Get-Content -LiteralPath $path -Encoding UTF8
$existing = @{}
foreach ($line in $content) {
    if ($line -match '^([A-Za-z0-9_]+)=') {
        $existing[$matches[1]] = $true
    }
}

$status = [ordered]@{
    "RANGER_ADMIN_INSTALL_STATUS" = "INSTALLED_ACTIVE"
    "RANGER_ADMIN_SERVICE" = "finance-ranger-admin"
    "RANGER_ADMIN_BIND" = "CLUSTER_NODE1_IP:6080"
    "RANGER_ADMIN_DB_TABLE_COUNT" = "78"
    "RANGER_USERSYNC_INSTALL_STATUS" = "INSTALLED_DISABLED_UNSAFE_5151_WILDCARD"
    "RANGER_USERSYNC_SERVICE" = "finance-ranger-usersync"
}

$added = New-Object System.Collections.Generic.List[string]
foreach ($key in $status.Keys) {
    if (-not $existing.ContainsKey($key)) {
        Add-Content -LiteralPath $path -Value "$key=$($status[$key])" -Encoding UTF8
        $added.Add($key)
    }
}

Write-Output ("added_status_keys=" + ($(if ($added.Count -gt 0) { $added -join "," } else { "none" })))

