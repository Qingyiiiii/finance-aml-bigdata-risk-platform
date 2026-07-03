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

set_line() {
  file="$1"
  key="$2"
  value="$3"
  if grep -q "^${key}=" "${file}"; then
    sed -i -E "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

echo "[atlas-reset] stop previous wait script if still alive"
for pid in $(pgrep -f 'atlas_fix_body' || true); do
  if [ "${pid}" != "$$" ]; then
    kill "${pid}" || true
  fi
done

echo "[atlas-reset] stop service and local children"
sudo_run systemctl stop "${SERVICE_NAME}" || true
"${ATLAS_HOME}/solr/bin/solr" stop -p "${ATLAS_SOLR_PORT}" >/dev/null 2>&1 || true
if [ -f "${ATLAS_HOME}/conf/zookeeper/zoo.cfg" ]; then
  "${ATLAS_HOME}/zk/bin/zkServer.sh" stop "${ATLAS_HOME}/conf/zookeeper/zoo.cfg" >/dev/null 2>&1 || true
fi
sleep 5

echo "[atlas-reset] clean local state"
rm -rf \
  "${ATLAS_DATA}/berkeley" \
  "${ATLAS_DATA}/solr" \
  "${ATLAS_DATA}/kafka" \
  "${ATLAS_DATA}/zookeeper" \
  "${ATLAS_HOME}/data/berkeley" \
  "${ATLAS_HOME}/data/solr" \
  "${ATLAS_HOME}/data/kafka" \
  "${ATLAS_HOME}/data/zookeeper"
mkdir -p "${ATLAS_DATA}/zookeeper/data" "${ATLAS_LOGS}/zookeeper"

echo "[atlas-reset] configure application"
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

echo "[atlas-reset] configure zookeeper"
for zk_file in "${ATLAS_HOME}/conf/zookeeper/zoo.cfg.template" "${ATLAS_HOME}/conf/zookeeper/zoo.cfg"; do
  if [ -f "${zk_file}" ]; then
    set_line "${zk_file}" "dataDir" "${ATLAS_DATA}/zookeeper/data"
    set_line "${zk_file}" "clientPort" "${ATLAS_ZK_PORT}"
    set_line "${zk_file}" "clientPortAddress" "127.0.0.1"
  fi
done

echo "[atlas-reset] configure solr bind"
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

echo "[atlas-reset] reset failed and start"
sudo_run systemctl reset-failed "${SERVICE_NAME}" || true
sudo_run systemctl start "${SERVICE_NAME}"

echo "[atlas-reset] short status"
sleep 30
systemctl is-active "${SERVICE_NAME}" || true
ss -ltnp | awk '$4 ~ /:(21000|9838|2182|9026|9027)$/ {print}' || true
for path in "/" "/login.jsp"; do
  code="$(curl -sS -o /tmp/atlas_reset_body -w '%{http_code}' --max-time 3 "http://${ATLAS_BIND_ADDRESS}:${ATLAS_HTTP_PORT}${path}" || true)"
  echo "path=${path} code=${code}"
done
rm -f /tmp/atlas_reset_body
