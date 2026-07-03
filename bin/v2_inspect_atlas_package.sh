set -euo pipefail

ATLAS_VERSION="2.5.0"
SRC_DIR="/export/build/apache-atlas-${ATLAS_VERSION}"
PKG="${SRC_DIR}/distro/target/apache-atlas-${ATLAS_VERSION}-bin.tar.gz"

echo "[atlas-package] package"
ls -lh "${PKG}"

echo "[atlas-package] top-level"
tar -tzf "${PKG}" | head -n 40 || true

echo "[atlas-package] conf-files"
tar -tzf "${PKG}" | grep -E '/conf/[^/]+$' | sort | head -n 80 || true

echo "[atlas-package] bin-files"
tar -tzf "${PKG}" | grep -E '/bin/[^/]+$' | sort | head -n 80 || true

echo "[atlas-package] app-properties-sample"
APP_PROP="$(tar -tzf "${PKG}" | grep -E '/conf/atlas-application.properties$' | head -n 1 || true)"
if [ -n "${APP_PROP}" ]; then
  tar -xOzf "${PKG}" "${APP_PROP}" \
    | grep -nE 'atlas.server|http.port|https.port|bind|address|auth|users|graph.storage|index.search|solr|berkeley|atlas\.home' \
    | head -n 160 \
    || true
else
  echo "__NO_ATLAS_APPLICATION_PROPERTIES__"
fi

echo "[atlas-source] bind-related"
grep -RInE 'atlas\.server\..*(bind|address|host)|http\.host|jetty.*host|setHost|Connector.*host|server\.http\.port' \
  "${SRC_DIR}/webapp" "${SRC_DIR}/distro" 2>/dev/null \
  | head -n 120 \
  || true
