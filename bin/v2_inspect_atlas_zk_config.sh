set -euo pipefail

ATLAS_VERSION="2.5.0"
SRC_DIR="/export/build/apache-atlas-${ATLAS_VERSION}"
PKG="${SRC_DIR}/distro/target/apache-atlas-${ATLAS_VERSION}-bin.tar.gz"

echo "[atlas-zk] zoo.cfg.template"
tar -xOzf "${PKG}" "apache-atlas-${ATLAS_VERSION}/conf/zookeeper/zoo.cfg.template" | sed -n '1,100p'

echo "[atlas-zk] is_zookeeper_local"
grep -n "def is_zookeeper_local" -A30 "${SRC_DIR}/distro/src/bin/atlas_config.py"
