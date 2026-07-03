set -euo pipefail

ATLAS_VERSION="2.5.0"
SRC_DIR="/export/build/apache-atlas-${ATLAS_VERSION}"
PKG="${SRC_DIR}/distro/target/apache-atlas-${ATLAS_VERSION}-bin.tar.gz"

echo "[atlas-runtime-bits] users-credentials"
tar -xOzf "${PKG}" "apache-atlas-${ATLAS_VERSION}/conf/users-credentials.properties" \
  | sed -n '1,80p'

echo "[atlas-runtime-bits] atlas-env"
tar -xOzf "${PKG}" "apache-atlas-${ATLAS_VERSION}/conf/atlas-env.sh" \
  | grep -nE 'JAVA_HOME|MANAGE_LOCAL|SOLR|ZOOKEEPER|OPTS|HEAP|ATLAS_HOME|ATLAS_LOG' \
  | head -n 120 \
  || true

echo "[atlas-runtime-bits] atlas-config-bind"
sed -n '60,100p' "${SRC_DIR}/distro/src/bin/atlas_config.py"

echo "[atlas-runtime-bits] embedded-server"
sed -n '50,140p' "${SRC_DIR}/webapp/src/main/java/org/apache/atlas/web/service/EmbeddedServer.java"
