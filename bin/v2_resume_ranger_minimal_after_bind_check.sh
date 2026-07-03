set -euo pipefail

RANGER_VERSION="2.6.0"
NODE_IP="CLUSTER_NODE1_IP"
ADMIN_URL="http://${NODE_IP}:6080"
ADMIN_HOME="/export/server/ranger-admin"
USERSYNC_HOME="/export/server/ranger-usersync"
LOG_DIR="/export/logs/ranger"
RUN_DIR="/export/run/ranger"
JAVA11_HOME="/usr/lib/jvm/java-11-openjdk"

echo "[ranger-resume] host=$(hostname) user=$(whoami)"

sudo systemctl daemon-reload
sudo systemctl restart finance-ranger-admin

READY=0
for _ in $(seq 1 60); do
  if curl -fsS --max-time 3 "${ADMIN_URL}/login.jsp" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done

if [ "${READY}" -ne 1 ]; then
  echo "[ranger-resume] Ranger Admin not ready; status follows" >&2
  sudo systemctl status finance-ranger-admin --no-pager -l >&2 || true
  sudo tail -n 120 "${LOG_DIR}/admin/catalina.out" >&2 || true
  exit 3
fi

echo "[ranger-resume] verify 6080 bind address"
SS_6080="$(ss -lntp | awk '$4 ~ /:6080$/ {print}')"
printf '%s\n' "${SS_6080}"
if printf '%s\n' "${SS_6080}" | grep -Eq '0\.0\.0\.0:6080|\[::\]:6080|\*:6080'; then
  echo "[ranger-resume] unsafe 6080 bind detected; stopping Ranger Admin" >&2
  sudo systemctl stop finance-ranger-admin || true
  exit 4
fi
if ! printf '%s\n' "${SS_6080}" | grep -Eq "(${NODE_IP}:6080|\\[::ffff:${NODE_IP//./\\.}\\]:6080)"; then
  echo "[ranger-resume] expected ${NODE_IP}:6080 listener not found; stopping Ranger Admin" >&2
  sudo systemctl stop finance-ranger-admin || true
  exit 5
fi

echo "[ranger-resume] run Ranger UserSync setup"
sudo mkdir -p "${LOG_DIR}/usersync" "${RUN_DIR}"
sudo mkdir -p "${USERSYNC_HOME}/conf"
sudo bash -c "cat > '${USERSYNC_HOME}/conf/java_home.sh'" <<EOF
export JAVA_HOME=${JAVA11_HOME}
EOF

USERSYNC_SETUP_LOG="${LOG_DIR}/usersync/setup.log"
set +e
sudo bash -c "cd '${USERSYNC_HOME}' && export JAVA_HOME='${JAVA11_HOME}' && export PATH='${JAVA11_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' && ./setup.sh > '${USERSYNC_SETUP_LOG}' 2>&1"
USERSYNC_SETUP_RC=$?
set -e
if [ "${USERSYNC_SETUP_RC}" -ne 0 ]; then
  echo "[ranger-resume] Ranger UserSync setup failed; sanitized tail follows" >&2
  sudo tail -n 120 "${USERSYNC_SETUP_LOG}" \
    | sed -E 's/(password|PASSWORD|PassWord)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\2***/g' >&2 || true
  exit "${USERSYNC_SETUP_RC}"
fi

sudo bash -c "cat > '${USERSYNC_HOME}/conf/ranger-usersync-env-v2.sh'" <<EOF
export JAVA_HOME=${JAVA11_HOME}
export logdir=${LOG_DIR}/usersync
export USERSYNC_PID_DIR_PATH=${RUN_DIR}
export USERSYNC_PID_NAME=usersync.pid
EOF

echo "[ranger-resume] install Ranger UserSync systemd unit"
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
  echo "[ranger-resume] 5151 listeners"
  printf '%s\n' "${SS_5151}"
  if printf '%s\n' "${SS_5151}" | grep -Eq '0\.0\.0\.0:5151|\[::\]:5151|\*:5151'; then
    echo "[ranger-resume] UserSync/UnixAuth uses unsafe 5151 wildcard bind; stopping UserSync and leaving it installed but disabled"
    sudo systemctl stop finance-ranger-usersync || true
    sudo systemctl disable finance-ranger-usersync >/dev/null || true
  fi
else
  echo "[ranger-resume] no 5151 listener detected after UserSync start"
fi

echo "[ranger-resume] final status"
systemctl is-active finance-ranger-admin
systemctl is-enabled finance-ranger-admin
curl -fsS --max-time 3 "${ADMIN_URL}/login.jsp" >/dev/null
echo "ranger_admin_url=${ADMIN_URL}"
echo "ranger_admin_home=${ADMIN_HOME}"
echo "ranger_usersync_home=${USERSYNC_HOME}"
echo "[ranger-resume] done"

