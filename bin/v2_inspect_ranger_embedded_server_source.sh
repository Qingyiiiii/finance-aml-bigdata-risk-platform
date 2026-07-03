set -euo pipefail

SRC_DIR="/export/build/apache-ranger-2.6.0"

echo "[embedded-server-files]"
find "${SRC_DIR}" -type f \( -name "*EmbeddedServer*.java" -o -name "*Embedded*.java" \) -printf '%p\n' | sort

echo "[port-host-source-grep]"
grep -RInE 'ranger.service.http.port|ranger.service.https.port|ranger.service.host|setAddress|Connector|addConnector|server.xml|address' \
  "${SRC_DIR}/security-admin" \
  | sed -n '1,220p' || true
