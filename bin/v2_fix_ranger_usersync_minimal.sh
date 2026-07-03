set -euo pipefail

RANGER_VERSION="2.6.0"
NODE_IP="CLUSTER_NODE1_IP"
ADMIN_URL="http://${NODE_IP}:6080"
USERSYNC_HOME="/export/server/ranger-usersync"
PKG_DIR="/export/packages/ranger"
LOG_DIR="/export/logs/ranger"
RUN_DIR="/export/run/ranger"
JAVA11_HOME="/usr/lib/jvm/java-11-openjdk"
HADOOP_CONF_DIR="/export/server/hadoop/etc/hadoop"

echo "[usersync-fix] host=$(hostname) user=$(whoami)"

CREDS="$(cat)"

get_cred() {
  local key="$1"
  printf '%s\n' "${CREDS}" \
    | tr -d '\r' \
    | awk -F= -v k="${key}" '$1 == k {v=substr($0, index($0, "=") + 1)} END {print v}'
}

require_cred() {
  local key="$1"
  local value
  value="$(get_cred "${key}")"
  if [ -z "${value}" ]; then
    echo "[usersync-fix] missing credential key: ${key}" >&2
    exit 2
  fi
  printf '%s' "${value}"
}

SUDO_PASSWORD="$(require_cred CLUSTER_HADOOP_COMMON_PASSWORD)"
RANGER_USERSYNC_PASSWORD="$(require_cred RANGER_USERSYNC_PASSWORD)"

printf '%s\n' "${SUDO_PASSWORD}" | sudo -S -p '' -v

echo "[usersync-fix] stop old usersync service"
sudo systemctl disable --now finance-ranger-usersync 2>/dev/null || true
sudo pkill -f -- '-[D]proc_rangerusersync' 2>/dev/null || true

TS="$(date +%Y%m%d_%H%M%S)"
if [ -e "${USERSYNC_HOME}" ]; then
  sudo mv "${USERSYNC_HOME}" "${USERSYNC_HOME}.bak.${TS}"
fi

echo "[usersync-fix] extract clean usersync package"
STAGE="/export/server/.ranger_usersync_stage_${TS}"
sudo mkdir -p "${STAGE}"
sudo tar -xzf "${PKG_DIR}/ranger-${RANGER_VERSION}-usersync.tar.gz" -C "${STAGE}"
sudo mv "${STAGE}/ranger-${RANGER_VERSION}-usersync" "${USERSYNC_HOME}"
sudo rmdir "${STAGE}"

echo "[usersync-fix] patch usersync runtime jars"
sudo mkdir -p "${USERSYNC_HOME}/dist" "${USERSYNC_HOME}/lib" "${USERSYNC_HOME}/conf" "${LOG_DIR}/usersync" "${RUN_DIR}"
sudo cp -f "/export/build/apache-ranger-${RANGER_VERSION}/unixauthservice/target/unixauthservice-${RANGER_VERSION}.jar" "${USERSYNC_HOME}/dist/"
sudo cp -f "/export/build/apache-ranger-${RANGER_VERSION}/ugsync/target/unixusersync-${RANGER_VERSION}.jar" "${USERSYNC_HOME}/lib/"
sudo cp -f "/export/build/apache-ranger-${RANGER_VERSION}/unixauthclient/target/unixauthclient-${RANGER_VERSION}.jar" "${USERSYNC_HOME}/lib/"
sudo cp -f /export/build/apache-ranger-${RANGER_VERSION}/security-admin/target/security-admin-web-${RANGER_VERSION}/WEB-INF/lib/*.jar "${USERSYNC_HOME}/lib/"
sudo bash -c "ln -sfn /export/server/hadoop/share/hadoop/common/*.jar '${USERSYNC_HOME}/lib/'"
sudo bash -c "ln -sfn /export/server/hadoop/share/hadoop/common/lib/*.jar '${USERSYNC_HOME}/lib/'"

echo "[usersync-fix] configure usersync install.properties"
sudo USERSYNC_HOME="${USERSYNC_HOME}" \
  ADMIN_URL="${ADMIN_URL}" \
  RANGER_USERSYNC_PASSWORD="${RANGER_USERSYNC_PASSWORD}" \
  HADOOP_CONF_DIR="${HADOOP_CONF_DIR}" \
  LOG_DIR="${LOG_DIR}" \
  RUN_DIR="${RUN_DIR}" \
  python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["USERSYNC_HOME"]) / "install.properties"
updates = {
    "ranger_base_dir": "/etc/ranger",
    "POLICY_MGR_URL": os.environ["ADMIN_URL"],
    "SYNC_SOURCE": "unix",
    "MIN_UNIX_USER_ID_TO_SYNC": "500",
    "MIN_UNIX_GROUP_ID_TO_SYNC": "500",
    "SYNC_INTERVAL": "5",
    "unix_user": "ranger",
    "unix_group": "ranger",
    "rangerUsersync_password": os.environ["RANGER_USERSYNC_PASSWORD"],
    "usersync_principal": "",
    "usersync_keytab": "",
    "hadoop_conf": os.environ["HADOOP_CONF_DIR"],
    "logdir": f"{os.environ['LOG_DIR']}/usersync",
    "USERSYNC_PID_DIR_PATH": os.environ["RUN_DIR"],
    "AUTH_SSL_ENABLED": "false",
}

lines = path.read_text(encoding="utf-8").splitlines()
seen = set()
out = []
for line in lines:
    stripped = line.strip()
    if stripped.startswith("#") or "=" not in stripped:
        out.append(line)
        continue
    key = stripped.split("=", 1)[0].strip()
    if key in updates:
        if key not in seen:
            out.append(f"{key}={updates[key]}")
            seen.add(key)
        continue
    out.append(line)

for key, value in updates.items():
    if key not in seen:
        out.append(f"{key}={value}")

path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY

sudo bash -c "cat > '${USERSYNC_HOME}/conf/java_home.sh'" <<EOF
export JAVA_HOME=${JAVA11_HOME}
EOF

echo "[usersync-fix] run setup"
USERSYNC_SETUP_LOG="${LOG_DIR}/usersync/setup.log"
set +e
sudo bash -c "cd '${USERSYNC_HOME}' && export JAVA_HOME='${JAVA11_HOME}' && export PATH='${JAVA11_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' && ./setup.sh > '${USERSYNC_SETUP_LOG}' 2>&1"
USERSYNC_SETUP_RC=$?
set -e
if [ "${USERSYNC_SETUP_RC}" -ne 0 ]; then
  echo "[usersync-fix] setup failed; sanitized tail follows" >&2
  sudo tail -n 160 "${USERSYNC_SETUP_LOG}" \
    | sed -E 's/(password|PASSWORD|PassWord)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\2***/g' >&2 || true
  exit "${USERSYNC_SETUP_RC}"
fi

sudo bash -c "cat > '${USERSYNC_HOME}/conf/ranger-usersync-env-v2.sh'" <<EOF
export JAVA_HOME=${JAVA11_HOME}
export logdir=${LOG_DIR}/usersync
export USERSYNC_PID_DIR_PATH=${RUN_DIR}
export USERSYNC_PID_NAME=usersync.pid
EOF

echo "[usersync-fix] install systemd unit"
sudo bash -c "cat > /etc/systemd/system/finance-ranger-usersync.service" <<EOF
[Unit]
Description=Finance BigData V2 Ranger UserSync
After=finance-ranger-admin.service
Requires=finance-ranger-admin.service

[Service]
Type=forking
Environment=JAVA_HOME=${JAVA11_HOME}
Environment=logdir=${LOG_DIR}/usersync
Environment=USERSYNC_PID_DIR_PATH=${RUN_DIR}
Environment=USERSYNC_PID_NAME=usersync.pid
PIDFile=${RUN_DIR}/usersync.pid
WorkingDirectory=${USERSYNC_HOME}
ExecStart=${USERSYNC_HOME}/ranger-usersync-services.sh start
ExecStop=${USERSYNC_HOME}/ranger-usersync-services.sh stop
Restart=on-failure
RestartSec=10
TimeoutStartSec=120
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable finance-ranger-usersync >/dev/null
sudo systemctl start finance-ranger-usersync || true
sleep 8

SS_5151="$(ss -lntp | awk '$4 ~ /:5151$/ {print}' || true)"
if [ -n "${SS_5151}" ]; then
  echo "[usersync-fix] 5151 listeners"
  printf '%s\n' "${SS_5151}"
  if printf '%s\n' "${SS_5151}" | grep -Eq '0\.0\.0\.0:5151|\[::\]:5151|\*:5151'; then
    echo "[usersync-fix] unsafe 5151 wildcard bind; stopping and disabling usersync"
    sudo systemctl stop finance-ranger-usersync || true
    sudo systemctl disable finance-ranger-usersync >/dev/null || true
  fi
else
  echo "[usersync-fix] no 5151 listener detected"
fi

echo "[usersync-fix] status"
systemctl is-active finance-ranger-admin
systemctl is-enabled finance-ranger-admin
systemctl is-active finance-ranger-usersync || true
systemctl is-enabled finance-ranger-usersync || true
echo "[usersync-fix] done"

