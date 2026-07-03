set -euo pipefail

ENV_FILE="$(mktemp)"
trap 'rm -f "${ENV_FILE}"' EXIT
cat > "${ENV_FILE}"
sed -i 's/\r$//' "${ENV_FILE}"
set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

: "${CLUSTER_HADOOP_COMMON_PASSWORD:?missing CLUSTER_HADOOP_COMMON_PASSWORD}"
: "${ATLAS_HOME:?missing ATLAS_HOME}"
: "${ATLAS_DATA:?missing ATLAS_DATA}"
: "${ATLAS_LOGS:?missing ATLAS_LOGS}"
: "${ATLAS_BIND_ADDRESS:?missing ATLAS_BIND_ADDRESS}"
: "${ATLAS_HTTP_PORT:?missing ATLAS_HTTP_PORT}"

SERVICE_NAME="finance-atlas"
ATLAS_ZK_PORT="2182"
ATLAS_SOLR_PORT="9838"
ATLAS_KAFKA_ZK_PORT="9026"
ATLAS_KAFKA_PORT="9027"

sudo_run() {
  printf '%s\n' "${CLUSTER_HADOOP_COMMON_PASSWORD}" | sudo -S -p '' "$@"
}

dedup_prop() {
  file="$1"
  key="$2"
  value="$3"
  tmp="$(mktemp)"
  awk -v k="${key}" '
    {
      line = $0
      sub(/^[# \t]*/, "", line)
      if (index(line, k "=") == 1) {
        next
      }
      print
    }
  ' "${file}" > "${tmp}"
  printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
}

echo "[atlas-fix] stop service"
sudo_run systemctl stop "${SERVICE_NAME}" || true
sleep 5

echo "[atlas-fix] clean first failed initialization data"
rm -rf \
  "${ATLAS_DATA}/berkeley" \
  "${ATLAS_DATA}/solr" \
  "${ATLAS_DATA}/kafka" \
  "${ATLAS_DATA}/zookeeper"
mkdir -p "${ATLAS_DATA}" "${ATLAS_LOGS}" "${ATLAS_LOGS}/zookeeper"

echo "[atlas-fix] dedupe atlas application properties"
APP="${ATLAS_HOME}/conf/atlas-application.properties"
dedup_prop "${APP}" "atlas.server.http.port" "${ATLAS_HTTP_PORT}"
dedup_prop "${APP}" "atlas.server.bind.address" "${ATLAS_BIND_ADDRESS}"
dedup_prop "${APP}" "atlas.rest.address" "http://${ATLAS_BIND_ADDRESS}:${ATLAS_HTTP_PORT}"
dedup_prop "${APP}" "atlas.server.ha.enabled" "false"
dedup_prop "${APP}" "atlas.server.run.setup.on.start" "false"
dedup_prop "${APP}" "atlas.graph.storage.backend" "berkeleyje"
dedup_prop "${APP}" "atlas.graph.storage.directory" "${ATLAS_DATA}/berkeley"
dedup_prop "${APP}" "atlas.graph.index.search.backend" "solr"
dedup_prop "${APP}" "atlas.graph.index.search.solr.mode" "cloud"
dedup_prop "${APP}" "atlas.graph.index.search.solr.zookeeper-url" "localhost:${ATLAS_ZK_PORT}"
dedup_prop "${APP}" "atlas.graph.index.search.solr.wait-searcher" "false"
dedup_prop "${APP}" "atlas.notification.embedded" "true"
dedup_prop "${APP}" "atlas.kafka.data" "${ATLAS_DATA}/kafka"
dedup_prop "${APP}" "atlas.kafka.zookeeper.connect" "127.0.0.1:${ATLAS_KAFKA_ZK_PORT}"
dedup_prop "${APP}" "atlas.kafka.bootstrap.servers" "127.0.0.1:${ATLAS_KAFKA_PORT}"

echo "[atlas-fix] ensure zookeeper config"
ZK_TMPL="${ATLAS_HOME}/conf/zookeeper/zoo.cfg.template"
ZK_CFG="${ATLAS_HOME}/conf/zookeeper/zoo.cfg"
if [ -f "${ZK_TMPL}" ]; then
  sed -i -E "s/^clientPort=.*/clientPort=${ATLAS_ZK_PORT}/" "${ZK_TMPL}"
  if grep -q '^clientPortAddress=' "${ZK_TMPL}"; then
    sed -i -E 's/^clientPortAddress=.*/clientPortAddress=127.0.0.1/' "${ZK_TMPL}"
  else
    printf '\nclientPortAddress=127.0.0.1\n' >> "${ZK_TMPL}"
  fi
fi
if [ -f "${ZK_CFG}" ]; then
  sed -i -E "s/^clientPort=.*/clientPort=${ATLAS_ZK_PORT}/" "${ZK_CFG}"
  if grep -q '^clientPortAddress=' "${ZK_CFG}"; then
    sed -i -E 's/^clientPortAddress=.*/clientPortAddress=127.0.0.1/' "${ZK_CFG}"
  else
    printf '\nclientPortAddress=127.0.0.1\n' >> "${ZK_CFG}"
  fi
fi

echo "[atlas-fix] ensure solr loopback bind"
SOLR_IN="${ATLAS_HOME}/solr/bin/solr.in.sh"
if grep -q '^SOLR_HOST=' "${SOLR_IN}"; then
  sed -i -E 's/^SOLR_HOST=.*/SOLR_HOST="127.0.0.1"/' "${SOLR_IN}"
else
  printf '\nSOLR_HOST="127.0.0.1"\n' >> "${SOLR_IN}"
fi
if ! grep -q 'finance-v2-jetty-host-bind' "${SOLR_IN}"; then
  cat >> "${SOLR_IN}" <<'EOF'

# finance-v2-jetty-host-bind
SOLR_OPTS="$SOLR_OPTS -Djetty.host=127.0.0.1"
EOF
fi

echo "[atlas-fix] reset failed state"
sudo_run systemctl reset-failed "${SERVICE_NAME}" || true

echo "[atlas-fix] verify single values"
awk '
  BEGIN {
    keys["atlas.graph.index.search.solr.mode"] = 0
    keys["atlas.graph.index.search.solr.zookeeper-url"] = 0
    keys["atlas.kafka.zookeeper.connect"] = 0
    keys["atlas.kafka.bootstrap.servers"] = 0
    keys["atlas.server.bind.address"] = 0
  }
  {
    line = $0
    sub(/^[# \t]*/, "", line)
    split(line, parts, "=")
    if (parts[1] in keys) {
      keys[parts[1]]++
    }
  }
  END {
    for (k in keys) {
      printf "%s=%d\n", k, keys[k]
      if (keys[k] != 1) {
        exit 1
      }
    }
  }
' "${APP}"

echo "[atlas-fix] start service"
sudo_run systemctl start "${SERVICE_NAME}"

echo "[atlas-fix] wait for non-503 http"
last_code="000"
for i in $(seq 1 120); do
  last_code="$(curl -sS -o /tmp/atlas_fix_body -w '%{http_code}' --max-time 5 "http://${ATLAS_BIND_ADDRESS}:${ATLAS_HTTP_PORT}/" || true)"
  if [ "${last_code}" != "000" ] && [ "${last_code}" != "503" ]; then
    break
  fi
  sleep 5
done
rm -f /tmp/atlas_fix_body
echo "[atlas-fix] final_http_code=${last_code}"
systemctl is-active "${SERVICE_NAME}"

echo "[atlas-fix] listeners"
listeners="$(ss -ltnp | awk '$4 ~ /:(21000|9838|2182|9026|9027)$/ {print}' || true)"
printf '%s\n' "${listeners}"
if printf '%s\n' "${listeners}" | grep -Eq '(^|[[:space:]])(\*|0\.0\.0\.0|\[::\]):(21000|9838|2182|9026|9027)([[:space:]]|$)'; then
  echo "__ATLAS_WILDCARD_LISTENER_DETECTED__"
  sudo_run systemctl stop "${SERVICE_NAME}" || true
  exit 1
fi
