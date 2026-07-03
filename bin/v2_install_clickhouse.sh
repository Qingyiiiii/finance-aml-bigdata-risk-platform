set -euo pipefail

echo "[clickhouse] host=$(hostname) user=$(whoami)"

if ! command -v clickhouse-client >/dev/null 2>&1; then
  echo "[clickhouse] installing rpm packages"
  sudo dnf -y install yum-utils dnf-plugins-core
  if ! sudo dnf config-manager --add-repo https://packages.clickhouse.com/rpm/clickhouse.repo; then
    sudo yum-config-manager --add-repo https://packages.clickhouse.com/rpm/clickhouse.repo
  fi
  sudo env CLICKHOUSE_SKIP_USER_SETUP=1 dnf -y install clickhouse-server clickhouse-client
else
  echo "[clickhouse] already installed: $(clickhouse-client --version 2>/dev/null || true)"
fi

echo "[clickhouse] configuring data and logs under /export"
sudo mkdir -p \
  /export/data/clickhouse/tmp \
  /export/data/clickhouse/user_files \
  /export/data/clickhouse/format_schemas \
  /export/logs/clickhouse \
  /etc/clickhouse-server/config.d

sudo chown -R clickhouse:clickhouse /export/data/clickhouse /export/logs/clickhouse

sudo tee /etc/clickhouse-server/config.d/finance_v2_paths.xml >/dev/null <<'XML'
<clickhouse>
    <path>/export/data/clickhouse/</path>
    <tmp_path>/export/data/clickhouse/tmp/</tmp_path>
    <user_files_path>/export/data/clickhouse/user_files/</user_files_path>
    <format_schema_path>/export/data/clickhouse/format_schemas/</format_schema_path>
    <listen_host>127.0.0.1</listen_host>
    <listen_host>CLUSTER_NODE1_IP</listen_host>
    <logger>
        <log>/export/logs/clickhouse/clickhouse-server.log</log>
        <errorlog>/export/logs/clickhouse/clickhouse-server.err.log</errorlog>
    </logger>
</clickhouse>
XML

echo "[clickhouse] starting service"
sudo systemctl enable clickhouse-server
sudo systemctl restart clickhouse-server

sleep 5

echo "[clickhouse] service status"
sudo systemctl --no-pager --full status clickhouse-server | sed -n '1,18p'

echo "[clickhouse] validation"
clickhouse-client --query "SELECT version() AS clickhouse_version"
clickhouse-client --query "CREATE DATABASE IF NOT EXISTS finance_bigdata_v2"
clickhouse-client --query "SHOW DATABASES LIKE 'finance_bigdata_v2'"
clickhouse-client --query "
CREATE TABLE IF NOT EXISTS finance_bigdata_v2.ads_account_risk_features
(
    account_number String,
    total_event_count UInt64,
    debit_count UInt64,
    credit_count UInt64,
    out_amount Decimal(20, 2),
    counterparty_count UInt64,
    laundering_event_count UInt64,
    cross_bank_event_count UInt64,
    cross_currency_event_count UInt64,
    risk_score_rule Float64,
    updated_at DateTime
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(updated_at)
ORDER BY (account_number, risk_score_rule)"
clickhouse-client --query "SHOW TABLES FROM finance_bigdata_v2"

echo "[clickhouse] listen ports"
ss -lntp | grep -E '8123|9000' || true

