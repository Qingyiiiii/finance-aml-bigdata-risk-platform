param(
    [string]$CredentialTemplate = "PRIVATE_CREDENTIALS_ENV"
)

$ErrorActionPreference = "Stop"

$required = [ordered]@{
    "RANGER_VERSION" = "2.6.0"
    "RANGER_ADMIN_URL" = "http://CLUSTER_NODE1_IP:6080"
    "RANGER_DB_NAME" = "ranger_admin"
    "RANGER_DB_USER" = "rangeradmin"
    "RANGER_DB_PASSWORD" = "<RANGER_DB_PASSWORD>"
    "RANGER_AUDIT_DB_NAME" = "ranger_audit"
    "RANGER_AUDIT_DB_USER" = "rangeraudit"
    "RANGER_AUDIT_DB_PASSWORD" = "<RANGER_AUDIT_DB_PASSWORD>"
    "RANGER_ADMIN_USERNAME" = "admin"
    "RANGER_ADMIN_PASSWORD" = "<RANGER_ADMIN_PASSWORD>"
    "RANGER_TAGSYNC_PASSWORD" = "<RANGER_TAGSYNC_PASSWORD>"
    "RANGER_USERSYNC_USERNAME" = "rangerusersync"
    "RANGER_USERSYNC_PASSWORD" = "<RANGER_USERSYNC_PASSWORD>"
    "RANGER_KEYADMIN_USERNAME" = "keyadmin"
    "RANGER_KEYADMIN_PASSWORD" = "<RANGER_KEYADMIN_PASSWORD>"
    "RANGER_UNIX_USER_PASSWORD" = "<RANGER_UNIX_USER_PASSWORD>"
}

$lines = foreach ($key in $required.Keys) {
    "$key=$($required[$key])"
}

Set-Content -LiteralPath $CredentialTemplate -Value $lines -Encoding UTF8
Write-Output "template_written=$CredentialTemplate"
