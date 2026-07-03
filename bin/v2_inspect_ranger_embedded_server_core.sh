set -euo pipefail

SRC="/export/build/apache-ranger-2.6.0/embeddedwebserver/src/main/java/org/apache/ranger/server/tomcat/EmbeddedServer.java"

echo "[embedded-server-core]"
grep -nE 'Connector|setPort|setAddress|getConfig|ranger.service|http|https|address' "${SRC}" | sed -n '1,200p'
echo "[embedded-server-source-1-240]"
sed -n '1,240p' "${SRC}"
