set -euo pipefail

OS_HOME="/export/server/opensearch"

echo "[opensearch-backup-postcheck] version"
OPENSEARCH_JAVA_HOME="${OS_HOME}/jdk" "${OS_HOME}/bin/opensearch" --version

echo "[opensearch-backup-postcheck] config"
grep -E '^(cluster.name|node.name|network.host|http.port|transport.port|discovery.type):' "${OS_HOME}/config/opensearch.yml"

echo "[opensearch-backup-postcheck] security disabled check"
if grep -R 'plugins.security.disabled: true' "${OS_HOME}/config" >/dev/null 2>&1; then
  echo "security_disabled_config=true"
  exit 2
fi
echo "security_disabled_config=false"

echo "[opensearch-backup-postcheck] listener check"
if ss -lntp | grep -E '19200|19300'; then
  echo "opensearch_backup_listening=true"
  exit 3
fi
echo "opensearch_backup_listening=false"

echo "[opensearch-backup-postcheck] paths"
ls -ld /export/server/opensearch /export/data/opensearch /export/logs/opensearch
