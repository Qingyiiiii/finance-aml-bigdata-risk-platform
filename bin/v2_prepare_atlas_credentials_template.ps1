param(
    [string]$CredentialTemplate = "PRIVATE_CREDENTIALS_ENV"
)

$ErrorActionPreference = "Stop"

$required = [ordered]@{
    "ATLAS_VERSION" = "2.5.0"
    "ATLAS_INSTALL_PROFILE" = "berkeley-solr"
    "ATLAS_HOME" = "/export/server/atlas"
    "ATLAS_DATA" = "/export/data/atlas"
    "ATLAS_LOGS" = "/export/logs/atlas"
    "ATLAS_BIND_ADDRESS" = "CLUSTER_NODE1_IP"
    "ATLAS_HTTP_PORT" = "21000"
    "ATLAS_ADMIN_URL" = "http://CLUSTER_NODE1_IP:21000"
    "ATLAS_ADMIN_USERNAME" = "admin"
    "ATLAS_ADMIN_PASSWORD" = "<ATLAS_ADMIN_PASSWORD>"
}

$lines = foreach ($key in $required.Keys) {
    "$key=$($required[$key])"
}

Set-Content -LiteralPath $CredentialTemplate -Value $lines -Encoding UTF8
Write-Output "template_written=$CredentialTemplate"
