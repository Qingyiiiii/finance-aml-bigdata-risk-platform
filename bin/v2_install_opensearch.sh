set -euo pipefail

source /etc/profile.d/bigdata.sh 2>/dev/null || true

OS_VERSION=3.6.0
OS_TGZ="opensearch-${OS_VERSION}-linux-x64.tar.gz"
OS_URL="https://artifacts.opensearch.org/releases/bundle/opensearch/${OS_VERSION}/${OS_TGZ}"
OS_HOME_VERSIONED="/export/server/opensearch-${OS_VERSION}"
OS_HOME="/export/server/opensearch"
OS_DATA="/export/data/opensearch"
OS_LOGS="/export/logs/opensearch"

echo "[opensearch-backup] host=$(hostname) user=$(whoami)"
echo "[opensearch-backup] version=${OS_VERSION}"
echo "[opensearch-backup] mode=installed backup only; service is not started"

echo "[download] ${OS_URL}"
sudo mkdir -p /export/packages /export/server "${OS_DATA}" "${OS_LOGS}"
sudo chown -R common:common /export/packages /export/server "${OS_DATA}" "${OS_LOGS}"
if [ ! -s "/export/packages/${OS_TGZ}" ]; then
  curl -fL --retry 3 --retry-delay 5 "${OS_URL}" -o "/export/packages/${OS_TGZ}"
else
  echo "[download] exists /export/packages/${OS_TGZ}"
fi

echo "[install] extract OpenSearch backup package"
if [ ! -d "${OS_HOME_VERSIONED}" ]; then
  tar -xzf "/export/packages/${OS_TGZ}" -C /export/server
fi
ln -sfn "${OS_HOME_VERSIONED}" "${OS_HOME}"
mkdir -p "${OS_DATA}" "${OS_LOGS}" "${OS_HOME}/config/jvm.options.d"
chown -R common:common "${OS_HOME_VERSIONED}" "${OS_DATA}" "${OS_LOGS}"
chown -h common:common "${OS_HOME}"

echo "[config] write backup config on non-conflicting ports"
cat > "${OS_HOME}/config/opensearch.yml" <<'EOF'
cluster.name: finance-bigdata-v2-opensearch-backup
node.name: hadoop1
path.data: /export/data/opensearch
path.logs: /export/logs/opensearch
network.host: CLUSTER_NODE1_IP
http.port: 19200
transport.port: 19300
discovery.type: single-node
EOF

cat > "${OS_HOME}/config/jvm.options.d/finance_v2_backup.options" <<'EOF'
-Xms1g
-Xmx1g
EOF

echo "[safety] ensure backup service is stopped if any old process exists"
if pgrep -f '[o]rg.opensearch.bootstrap.OpenSearch' >/dev/null 2>&1; then
  pkill -f '[o]rg.opensearch.bootstrap.OpenSearch' >/dev/null 2>&1 || true
fi
sudo systemctl disable opensearch-finance-v2 >/dev/null 2>&1 || true
sudo systemctl stop opensearch-finance-v2 >/dev/null 2>&1 || true

echo "[validation] version"
OPENSEARCH_JAVA_HOME="${OS_HOME}/jdk" "${OS_HOME}/bin/opensearch" --version

echo "[validation] security plugin is not disabled in config"
if grep -R 'plugins.security.disabled: true' "${OS_HOME}/config" >/dev/null 2>&1; then
  echo "[opensearch-backup] unsafe config found: plugins.security.disabled=true" >&2
  exit 2
fi
echo "security_disabled_config=false"

echo "[validation] backup ports should not be listening"
if ss -lntp | grep -E '19200|19300'; then
  echo "[opensearch-backup] unexpected OpenSearch listener found" >&2
  exit 3
fi
echo "opensearch_backup_listening=false"

echo "[validation] install paths"
ls -ld "${OS_HOME_VERSIONED}" "${OS_HOME}" "${OS_DATA}" "${OS_LOGS}"

echo "[opensearch-backup] done"

