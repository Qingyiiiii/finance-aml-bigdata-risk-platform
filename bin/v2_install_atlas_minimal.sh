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
: "${ATLAS_VERSION:?missing ATLAS_VERSION}"
: "${ATLAS_HOME:?missing ATLAS_HOME}"
: "${ATLAS_DATA:?missing ATLAS_DATA}"
: "${ATLAS_LOGS:?missing ATLAS_LOGS}"
: "${ATLAS_BIND_ADDRESS:?missing ATLAS_BIND_ADDRESS}"
: "${ATLAS_HTTP_PORT:?missing ATLAS_HTTP_PORT}"
: "${ATLAS_ADMIN_USERNAME:?missing ATLAS_ADMIN_USERNAME}"
: "${ATLAS_ADMIN_PASSWORD:?missing ATLAS_ADMIN_PASSWORD}"

SRC_DIR="/export/build/apache-atlas-${ATLAS_VERSION}"
PKG="${SRC_DIR}/distro/target/apache-atlas-${ATLAS_VERSION}-bin.tar.gz"
INSTALL_PARENT="$(dirname "${ATLAS_HOME}")"
SERVICE_NAME="finance-atlas"
ATLAS_ZK_PORT="2182"
ATLAS_SOLR_PORT="9838"
ATLAS_KAFKA_ZK_PORT="9026"
ATLAS_KAFKA_PORT="9027"

sudo_run() {
  printf '%s\n' "${CLUSTER_HADOOP_COMMON_PASSWORD}" | sudo -S -p '' "$@"
}

set_prop() {
  file="$1"
  key="$2"
  value="$3"
  regex_key="$(printf '%s' "${key}" | sed 's/[.[\*^$()+?{}|]/\\&/g')"
  value_sed="$(printf '%s' "${value}" | sed 's/[&|]/\\&/g')"
  if grep -Eq "^[#[:space:]]*${regex_key}=" "${file}"; then
    sed -i -E "s|^[#[:space:]]*${regex_key}=.*|${key}=${value_sed}|" "${file}"
  else
    printf '\n%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

require_file() {
  if [ ! -f "$1" ]; then
    echo "__MISSING_FILE__ $1"
    exit 1
  fi
}

echo "[atlas-install] preflight"
require_file "${PKG}"
if [ ! -x "/export/server/jdk8/bin/java" ]; then
  echo "__MISSING_JDK8__ /export/server/jdk8/bin/java"
  exit 1
fi

echo "[atlas-install] stop existing service if present"
if systemctl list-unit-files | awk '{print $1}' | grep -qx "${SERVICE_NAME}.service"; then
  sudo_run systemctl stop "${SERVICE_NAME}" || true
fi

echo "[atlas-install] prepare directories"
sudo_run mkdir -p "${INSTALL_PARENT}" "${ATLAS_DATA}" "${ATLAS_LOGS}"
sudo_run chown -R common:common "${ATLAS_DATA}" "${ATLAS_LOGS}"

if [ -d "${ATLAS_HOME}" ]; then
  backup="${ATLAS_HOME}.backup.$(date +%Y%m%d_%H%M%S)"
  echo "[atlas-install] backup existing atlas home to ${backup}"
  sudo_run mv "${ATLAS_HOME}" "${backup}"
fi

echo "[atlas-install] extract package"
sudo_run tar -xzf "${PKG}" -C "${INSTALL_PARENT}"
sudo_run mv "${INSTALL_PARENT}/apache-atlas-${ATLAS_VERSION}" "${ATLAS_HOME}"
sudo_run chown -R common:common "${ATLAS_HOME}"
chmod +x "${ATLAS_HOME}"/bin/*.py || true

echo "[atlas-install] configure atlas-env"
cat >> "${ATLAS_HOME}/conf/atlas-env.sh" <<EOF

# Finance bigdata V2 minimal Atlas runtime.
export JAVA_HOME=/export/server/jdk8
export ATLAS_HOME_DIR=${ATLAS_HOME}
export ATLAS_CONF=${ATLAS_HOME}/conf
export ATLAS_LOG_DIR=${ATLAS_LOGS}
export ATLAS_PID_DIR=${ATLAS_LOGS}
export ATLAS_DATA_DIR=${ATLAS_DATA}
export ATLAS_SERVER_HEAP="-Xms1g -Xmx2g -XX:MaxMetaspaceSize=512m"
export MANAGE_LOCAL_HBASE=false
export MANAGE_LOCAL_SOLR=true
export MANAGE_LOCAL_ELASTICSEARCH=false
export SOLR_HOME=${ATLAS_DATA}/solr
export SOLR_PORT=${ATLAS_SOLR_PORT}
export SOLR_JETTY_HOST=127.0.0.1
export SOLR_OPTS="\${SOLR_OPTS:-} -Djetty.host=127.0.0.1"
export ZOO_LOG_DIR=${ATLAS_LOGS}/zookeeper
EOF

echo "[atlas-install] configure atlas application"
APP="${ATLAS_HOME}/conf/atlas-application.properties"
set_prop "${APP}" "atlas.server.http.port" "${ATLAS_HTTP_PORT}"
set_prop "${APP}" "atlas.server.bind.address" "${ATLAS_BIND_ADDRESS}"
set_prop "${APP}" "atlas.rest.address" "http://${ATLAS_BIND_ADDRESS}:${ATLAS_HTTP_PORT}"
set_prop "${APP}" "atlas.server.ha.enabled" "false"
set_prop "${APP}" "atlas.server.run.setup.on.start" "false"
set_prop "${APP}" "atlas.graph.storage.backend" "berkeleyje"
set_prop "${APP}" "atlas.graph.storage.directory" "${ATLAS_DATA}/berkeley"
set_prop "${APP}" "atlas.graph.index.search.backend" "solr"
set_prop "${APP}" "atlas.graph.index.search.solr.mode" "cloud"
set_prop "${APP}" "atlas.graph.index.search.solr.zookeeper-url" "localhost:${ATLAS_ZK_PORT}"
set_prop "${APP}" "atlas.notification.embedded" "true"
set_prop "${APP}" "atlas.kafka.data" "${ATLAS_DATA}/kafka"
set_prop "${APP}" "atlas.kafka.zookeeper.connect" "127.0.0.1:${ATLAS_KAFKA_ZK_PORT}"
set_prop "${APP}" "atlas.kafka.bootstrap.servers" "127.0.0.1:${ATLAS_KAFKA_PORT}"

echo "[atlas-install] configure atlas local zookeeper"
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

echo "[atlas-install] configure local solr bind"
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

echo "[atlas-install] configure credentials"
admin_hash="$(printf '%s' "${ATLAS_ADMIN_PASSWORD}" | sha256sum | awk '{print $1}')"
{
  printf '#username=group::sha256-password\n'
  printf '%s=ADMIN::%s\n' "${ATLAS_ADMIN_USERNAME}" "${admin_hash}"
  if [ -n "${RANGER_TAGSYNC_PASSWORD:-}" ]; then
    tagsync_hash="$(printf '%s' "${RANGER_TAGSYNC_PASSWORD}" | sha256sum | awk '{print $1}')"
    printf 'rangertagsync=RANGER_TAG_SYNC::%s\n' "${tagsync_hash}"
  fi
} > "${ATLAS_HOME}/conf/users-credentials.properties"
chmod 600 "${ATLAS_HOME}/conf/users-credentials.properties"

echo "[atlas-install] write systemd service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SERVICE_TMP="$(mktemp)"
cat > "${SERVICE_TMP}" <<EOF
[Unit]
Description=Finance BigData V2 Apache Atlas
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=common
Group=common
WorkingDirectory=${ATLAS_HOME}
Environment=JAVA_HOME=/export/server/jdk8
Environment=ATLAS_HOME_DIR=${ATLAS_HOME}
Environment=ATLAS_CONF=${ATLAS_HOME}/conf
Environment=ATLAS_LOG_DIR=${ATLAS_LOGS}
Environment=ATLAS_PID_DIR=${ATLAS_LOGS}
Environment=ATLAS_DATA_DIR=${ATLAS_DATA}
Environment=MANAGE_LOCAL_HBASE=false
Environment=MANAGE_LOCAL_SOLR=true
Environment=MANAGE_LOCAL_ELASTICSEARCH=false
Environment=SOLR_HOME=${ATLAS_DATA}/solr
Environment=SOLR_PORT=${ATLAS_SOLR_PORT}
Environment=SOLR_JETTY_HOST=127.0.0.1
Environment=ZOO_LOG_DIR=${ATLAS_LOGS}/zookeeper
PIDFile=${ATLAS_LOGS}/atlas.pid
ExecStart=${ATLAS_HOME}/bin/atlas_start.py
ExecStop=${ATLAS_HOME}/bin/atlas_stop.py
TimeoutStartSec=600
TimeoutStopSec=180
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
sudo_run cp "${SERVICE_TMP}" "${SERVICE_FILE}"
rm -f "${SERVICE_TMP}"
sudo_run systemctl daemon-reload
sudo_run systemctl enable "${SERVICE_NAME}"

echo "[atlas-install] firewall internal http port"
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
  sudo_run firewall-cmd --permanent --add-port="${ATLAS_HTTP_PORT}/tcp" >/dev/null
  sudo_run firewall-cmd --reload >/dev/null
else
  echo "__FIREWALLD_NOT_ACTIVE_OR_MISSING__"
fi

echo "[atlas-install] start service"
sudo_run systemctl start "${SERVICE_NAME}"

echo "[atlas-install] wait for http"
for i in $(seq 1 90); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://${ATLAS_BIND_ADDRESS}:${ATLAS_HTTP_PORT}/" || true)"
  if [ "${code}" != "000" ]; then
    echo "[atlas-install] http_code=${code}"
    break
  fi
  sleep 5
  if [ "${i}" = "90" ]; then
    echo "__ATLAS_HTTP_TIMEOUT__"
    sudo_run systemctl status "${SERVICE_NAME}" --no-pager || true
    exit 1
  fi
done

echo "[atlas-install] service status"
systemctl is-active "${SERVICE_NAME}"

echo "[atlas-install] listeners"
listeners="$(ss -ltnp | awk '$4 ~ /:(21000|9838|2182|9026|9027)$/ {print}' || true)"
printf '%s\n' "${listeners}"
if printf '%s\n' "${listeners}" | grep -Eq '(^|[[:space:]])(\*|0\.0\.0\.0|\[::\]):(21000|9838|2182|9026|9027)([[:space:]]|$)'; then
  echo "__ATLAS_WILDCARD_LISTENER_DETECTED__"
  sudo_run systemctl stop "${SERVICE_NAME}" || true
  exit 1
fi

echo "[atlas-install] complete"
