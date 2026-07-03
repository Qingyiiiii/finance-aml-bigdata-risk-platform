set -euo pipefail

ATLAS_HOME="/export/server/atlas"
ATLAS_LOGS="/export/logs/atlas"
SERVICE_NAME="finance-atlas"

echo "[atlas-check] service"
systemctl is-active "${SERVICE_NAME}" || true
systemctl --no-pager --full status "${SERVICE_NAME}" | sed -n '1,40p' || true

echo "[atlas-check] processes"
ps -eo pid,ppid,etime,pcpu,pmem,comm,args --no-headers \
  | awk '/[a]tlas|[s]olr|[z]kServer|[k]afka|[j]anus|[o]rg.apache/ {print}' \
  | head -n 80 \
  || true

echo "[atlas-check] listeners"
listeners="$(ss -ltnp | awk '$4 ~ /:(21000|9838|2182|9026|9027)$/ {print}' || true)"
printf '%s\n' "${listeners}"
if printf '%s\n' "${listeners}" | grep -Eq '(^|[[:space:]])(\*|0\.0\.0\.0|\[::\]):(21000|9838|2182|9026|9027)([[:space:]]|$)'; then
  echo "__ATLAS_WILDCARD_LISTENER_DETECTED__"
fi

echo "[atlas-check] http"
for path in "/" "/login.jsp" "/api/atlas/admin/status" "/api/atlas/admin/version"; do
  code="$(curl -sS -o /tmp/atlas_check_body -w '%{http_code}' --max-time 10 "http://CLUSTER_NODE1_IP:21000${path}" || true)"
  bytes="$(wc -c </tmp/atlas_check_body 2>/dev/null || echo 0)"
  echo "path=${path} code=${code} bytes=${bytes}"
done
rm -f /tmp/atlas_check_body

echo "[atlas-check] config"
grep -nE '^(atlas.server.http.port|atlas.server.bind.address|atlas.rest.address|atlas.graph.storage.backend|atlas.graph.storage.directory|atlas.graph.index.search.solr.zookeeper-url|atlas.kafka.zookeeper.connect|atlas.kafka.bootstrap.servers)=' \
  "${ATLAS_HOME}/conf/atlas-application.properties" \
  || true
if [ -f "${ATLAS_HOME}/conf/zookeeper/zoo.cfg" ]; then
  grep -nE '^(clientPort|clientPortAddress)=' "${ATLAS_HOME}/conf/zookeeper/zoo.cfg" || true
else
  echo "__NO_ATLAS_ZOO_CFG__"
fi

echo "[atlas-check] log-tail"
find "${ATLAS_LOGS}" -maxdepth 2 -type f \( -name "*.log" -o -name "*.out" \) -printf '%T@ %p\n' \
  | sort -nr \
  | head -n 5 \
  | awk '{print $2}' \
  | while read -r log; do
      echo "--- ${log}"
      tail -n 80 "${log}" \
        | grep -E 'ERROR|WARN|Started|started|Exception|ACTIVE|Service|Solr|ZooKeeper|Kafka|Atlas Server|HTTP|503' \
        | tail -n 60 \
        || true
    done

