set -euo pipefail

ADMIN_DIR="/tmp/ranger_admin_inspect/ranger-2.6.0-admin"

echo "[conf-dist-port-props]"
grep -RInE 'ranger.service.http.port|ranger.service.https.port|ranger.service.host|http.port|bind|address|6080|server.port' \
  "${ADMIN_DIR}/ews/webapp/WEB-INF/classes/conf.dist" \
  "${ADMIN_DIR}/ews/webapp/WEB-INF/classes/conf" 2>/dev/null \
  | sed -n '1,220p' || true

echo "[embedded-server-strings]"
find "${ADMIN_DIR}/ews/webapp/WEB-INF/lib" -maxdepth 1 -type f -name "*.jar" \
  | while read -r jar; do
      hit="$(strings "${jar}" | grep -E 'ranger.service.http.port|ranger.service.host|server.address|Connector|EmbeddedServer|setAddress' | sed -n '1,40p' || true)"
      if [ -n "${hit}" ]; then
        echo "JAR=${jar}"
        printf '%s\n' "${hit}"
      fi
    done
