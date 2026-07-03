set -euo pipefail

RANGER_VERSION="2.6.0"
NODE_IP="CLUSTER_NODE1_IP"
ADMIN_URL="http://${NODE_IP}:6080"
ADMIN_HOME="/export/server/ranger-admin"
USERSYNC_HOME="/export/server/ranger-usersync"
PKG_DIR="/export/packages/ranger"
DATA_DIR="/export/data/ranger"
LOG_DIR="/export/logs/ranger"
RUN_DIR="/export/run/ranger"
JAVA11_HOME="/usr/lib/jvm/java-11-openjdk"
HADOOP_CONF_DIR="/export/server/hadoop/etc/hadoop"

echo "[ranger-install] host=$(hostname) user=$(whoami)"

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
    echo "[ranger-install] missing credential key: ${key}" >&2
    exit 2
  fi
  printf '%s' "${value}"
}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

SUDO_PASSWORD="$(require_cred CLUSTER_HADOOP_COMMON_PASSWORD)"
RANGER_DB_NAME="$(require_cred RANGER_DB_NAME)"
RANGER_DB_USER="$(require_cred RANGER_DB_USER)"
RANGER_DB_PASSWORD="$(require_cred RANGER_DB_PASSWORD)"
RANGER_AUDIT_DB_NAME="$(require_cred RANGER_AUDIT_DB_NAME)"
RANGER_AUDIT_DB_USER="$(require_cred RANGER_AUDIT_DB_USER)"
RANGER_AUDIT_DB_PASSWORD="$(require_cred RANGER_AUDIT_DB_PASSWORD)"
RANGER_ADMIN_PASSWORD="$(require_cred RANGER_ADMIN_PASSWORD)"
RANGER_TAGSYNC_PASSWORD="$(require_cred RANGER_TAGSYNC_PASSWORD)"
RANGER_USERSYNC_PASSWORD="$(require_cred RANGER_USERSYNC_PASSWORD)"
RANGER_KEYADMIN_PASSWORD="$(require_cred RANGER_KEYADMIN_PASSWORD)"
RANGER_UNIX_USER_PASSWORD="$(require_cred RANGER_UNIX_USER_PASSWORD)"

sudo_refresh() {
  printf '%s\n' "${SUDO_PASSWORD}" | sudo -S -p '' -v
}

mask_tail() {
  local file="$1"
  tail -n 120 "${file}" 2>/dev/null \
    | sed -E 's/(password|PASSWORD|PassWord)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\2***/g' || true
}

sudo_refresh

echo "[ranger-install] prerequisite packages"
if ! command -v bc >/dev/null 2>&1 || [ ! -s /usr/share/java/postgresql.jar ]; then
  sudo dnf -y install bc postgresql-jdbc
fi

echo "[ranger-install] start PostgreSQL if needed"
sudo systemctl start postgresql || sudo systemctl start postgresql-15

echo "[ranger-install] create PostgreSQL roles and databases"
RANGER_DB_PASSWORD_SQL="$(sql_escape "${RANGER_DB_PASSWORD}")"
RANGER_AUDIT_DB_PASSWORD_SQL="$(sql_escape "${RANGER_AUDIT_DB_PASSWORD}")"
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
ALTER SYSTEM SET password_encryption = 'md5';
SELECT pg_reload_conf();
SET password_encryption = 'md5';

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${RANGER_DB_USER}') THEN
    CREATE ROLE ${RANGER_DB_USER} LOGIN PASSWORD '${RANGER_DB_PASSWORD_SQL}';
  ELSE
    ALTER ROLE ${RANGER_DB_USER} WITH LOGIN PASSWORD '${RANGER_DB_PASSWORD_SQL}';
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${RANGER_AUDIT_DB_USER}') THEN
    CREATE ROLE ${RANGER_AUDIT_DB_USER} LOGIN PASSWORD '${RANGER_AUDIT_DB_PASSWORD_SQL}';
  ELSE
    ALTER ROLE ${RANGER_AUDIT_DB_USER} WITH LOGIN PASSWORD '${RANGER_AUDIT_DB_PASSWORD_SQL}';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE ${RANGER_DB_NAME} OWNER ${RANGER_DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${RANGER_DB_NAME}')\gexec
ALTER DATABASE ${RANGER_DB_NAME} OWNER TO ${RANGER_DB_USER};
GRANT ALL PRIVILEGES ON DATABASE ${RANGER_DB_NAME} TO ${RANGER_DB_USER};

SELECT 'CREATE DATABASE ${RANGER_AUDIT_DB_NAME} OWNER ${RANGER_AUDIT_DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${RANGER_AUDIT_DB_NAME}')\gexec
ALTER DATABASE ${RANGER_AUDIT_DB_NAME} OWNER TO ${RANGER_AUDIT_DB_USER};
GRANT ALL PRIVILEGES ON DATABASE ${RANGER_AUDIT_DB_NAME} TO ${RANGER_AUDIT_DB_USER};

\c ${RANGER_DB_NAME}
GRANT ALL ON SCHEMA public TO ${RANGER_DB_USER};
ALTER SCHEMA public OWNER TO ${RANGER_DB_USER};

\c ${RANGER_AUDIT_DB_NAME}
GRANT ALL ON SCHEMA public TO ${RANGER_AUDIT_DB_USER};
ALTER SCHEMA public OWNER TO ${RANGER_AUDIT_DB_USER};
SQL

echo "[ranger-install] prepare directories"
sudo mkdir -p /export/server "${DATA_DIR}" "${LOG_DIR}/admin" "${LOG_DIR}/usersync" "${RUN_DIR}"
sudo chmod 750 "${DATA_DIR}" "${LOG_DIR}/admin" "${LOG_DIR}/usersync" "${RUN_DIR}"

echo "[ranger-install] stop existing Ranger services if present"
sudo systemctl stop finance-ranger-usersync 2>/dev/null || true
sudo systemctl stop finance-ranger-admin 2>/dev/null || true
if [ -x /usr/bin/ranger-usersync ]; then sudo /usr/bin/ranger-usersync stop 2>/dev/null || true; fi
if [ -x /usr/bin/ranger-admin ]; then sudo /usr/bin/ranger-admin stop 2>/dev/null || true; fi
sudo pkill -f -- '-[D]proc_rangerusersync' 2>/dev/null || true
sudo pkill -f -- '-[D]proc_rangeradmin' 2>/dev/null || true

TS="$(date +%Y%m%d_%H%M%S)"
for path in "${ADMIN_HOME}" "${USERSYNC_HOME}"; do
  if [ -e "${path}" ]; then
    sudo mv "${path}" "${path}.bak.${TS}"
  fi
done

echo "[ranger-install] extract Ranger Admin and UserSync"
STAGE="/export/server/.ranger_v2_stage_${TS}"
sudo mkdir -p "${STAGE}"
sudo tar -xzf "${PKG_DIR}/ranger-${RANGER_VERSION}-admin.tar.gz" -C "${STAGE}"
sudo tar -xzf "${PKG_DIR}/ranger-${RANGER_VERSION}-usersync.tar.gz" -C "${STAGE}"
sudo mv "${STAGE}/ranger-${RANGER_VERSION}-admin" "${ADMIN_HOME}"
sudo mv "${STAGE}/ranger-${RANGER_VERSION}-usersync" "${USERSYNC_HOME}"
sudo rmdir "${STAGE}"

WEBAPP_BUILD="/export/build/apache-ranger-${RANGER_VERSION}/security-admin/target/security-admin-web-${RANGER_VERSION}"
if [ -d "${WEBAPP_BUILD}/WEB-INF/classes/conf.dist" ] && [ -d "${WEBAPP_BUILD}/WEB-INF/lib" ]; then
  echo "[ranger-install] patch Admin package with built webapp content"
  sudo mkdir -p "${ADMIN_HOME}/ews/webapp"
  sudo cp -a "${WEBAPP_BUILD}/." "${ADMIN_HOME}/ews/webapp/"
else
  echo "[ranger-install] built webapp content missing at ${WEBAPP_BUILD}" >&2
  exit 6
fi

echo "[ranger-install] patch Admin package with setup helper jars"
sudo mkdir -p "${ADMIN_HOME}/jisql/lib" "${ADMIN_HOME}/cred/lib"
sudo cp -f "/export/maven_repo/org/apache/ranger/jisql/${RANGER_VERSION}/jisql-${RANGER_VERSION}.jar" "${ADMIN_HOME}/jisql/lib/"
sudo cp -f "/export/maven_repo/net/sf/jopt-simple/jopt-simple/5.0.4/jopt-simple-5.0.4.jar" "${ADMIN_HOME}/jisql/lib/"
sudo cp -f "/export/maven_repo/org/apache/ranger/credentialbuilder/${RANGER_VERSION}/credentialbuilder-${RANGER_VERSION}.jar" "${ADMIN_HOME}/cred/lib/"
sudo cp -f "/export/maven_repo/org/apache/ranger/ranger-util/${RANGER_VERSION}/ranger-util-${RANGER_VERSION}.jar" "${ADMIN_HOME}/cred/lib/"
sudo bash -c "ln -sfn /export/server/hadoop/share/hadoop/common/*.jar '${ADMIN_HOME}/cred/lib/'"
sudo bash -c "ln -sfn /export/server/hadoop/share/hadoop/common/lib/*.jar '${ADMIN_HOME}/cred/lib/'"

echo "[ranger-install] configure install.properties"
sudo ADMIN_HOME="${ADMIN_HOME}" \
  USERSYNC_HOME="${USERSYNC_HOME}" \
  JAVA11_HOME="${JAVA11_HOME}" \
  HADOOP_CONF_DIR="${HADOOP_CONF_DIR}" \
  NODE_IP="${NODE_IP}" \
  ADMIN_URL="${ADMIN_URL}" \
  RANGER_DB_NAME="${RANGER_DB_NAME}" \
  RANGER_DB_USER="${RANGER_DB_USER}" \
  RANGER_DB_PASSWORD="${RANGER_DB_PASSWORD}" \
  RANGER_ADMIN_PASSWORD="${RANGER_ADMIN_PASSWORD}" \
  RANGER_TAGSYNC_PASSWORD="${RANGER_TAGSYNC_PASSWORD}" \
  RANGER_USERSYNC_PASSWORD="${RANGER_USERSYNC_PASSWORD}" \
  RANGER_KEYADMIN_PASSWORD="${RANGER_KEYADMIN_PASSWORD}" \
  RANGER_UNIX_USER_PASSWORD="${RANGER_UNIX_USER_PASSWORD}" \
  LOG_DIR="${LOG_DIR}" \
  RUN_DIR="${RUN_DIR}" \
  python3 - <<'PY'
import os
from pathlib import Path


def update_properties(path: Path, updates: dict[str, str]) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        stripped_line = line.strip()
        key = ""
        if not stripped_line.startswith("#") and "=" in stripped_line:
            key = stripped_line.split("=", 1)[0].strip()
        if key in updates:
            out.append(f"{key}={updates[key]}")
            seen.add(key)
        else:
            out.append(line)
    for key, value in updates.items():
        if key not in seen:
            out.append(f"{key}={value}")
    path.write_text("\n".join(out) + "\n", encoding="utf-8")


admin_home = Path(os.environ["ADMIN_HOME"])
usersync_home = Path(os.environ["USERSYNC_HOME"])
log_dir = os.environ["LOG_DIR"]
run_dir = os.environ["RUN_DIR"]

update_properties(
    admin_home / "install.properties",
    {
        "setup_mode": "SeparateDBA",
        "PYTHON_COMMAND_INVOKER": "python3",
        "DB_FLAVOR": "POSTGRES",
        "SQL_CONNECTOR_JAR": "/usr/share/java/postgresql.jar",
        "db_root_user": "postgres",
        "db_root_password": "",
        "db_host": "127.0.0.1:5432",
        "db_name": os.environ["RANGER_DB_NAME"],
        "db_user": os.environ["RANGER_DB_USER"],
        "db_password": os.environ["RANGER_DB_PASSWORD"],
        "rangerAdmin_password": os.environ["RANGER_ADMIN_PASSWORD"],
        "rangerTagsync_password": os.environ["RANGER_TAGSYNC_PASSWORD"],
        "rangerUsersync_password": os.environ["RANGER_USERSYNC_PASSWORD"],
        "keyadmin_password": os.environ["RANGER_KEYADMIN_PASSWORD"],
        "audit_store": "",
        "audit_solr_urls": "",
        "audit_elasticsearch_urls": "",
        "policymgr_external_url": os.environ["ADMIN_URL"],
        "policymgr_http_enabled": "true",
        "authentication_method": "NONE",
        "remoteLoginEnabled": "false",
        "authServiceHostName": "127.0.0.1",
        "authServicePort": "5151",
        "unix_user": "ranger",
        "unix_user_pwd": os.environ["RANGER_UNIX_USER_PASSWORD"],
        "unix_group": "ranger",
        "hadoop_conf": os.environ["HADOOP_CONF_DIR"],
        "RANGER_ADMIN_LOG_DIR": f"{log_dir}/admin",
        "RANGER_PID_DIR_PATH": run_dir,
        "JAVA_BIN": f"{os.environ['JAVA11_HOME']}/bin/java",
        "ranger_admin_max_heap_size": "512m",
    },
)

update_properties(
    usersync_home / "install.properties",
    {
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
        "logdir": f"{log_dir}/usersync",
        "USERSYNC_PID_DIR_PATH": run_dir,
        "AUTH_SSL_ENABLED": "false",
    },
)
PY

echo "[ranger-install] run Ranger Admin setup"
ADMIN_SETUP_LOG="${LOG_DIR}/admin/setup.log"
set +e
sudo bash -c "cd '${ADMIN_HOME}' && export JAVA_HOME='${JAVA11_HOME}' && export PATH='${JAVA11_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' && ./setup.sh > '${ADMIN_SETUP_LOG}' 2>&1"
ADMIN_SETUP_RC=$?
set -e
if [ "${ADMIN_SETUP_RC}" -ne 0 ]; then
  echo "[ranger-install] Ranger Admin setup failed; sanitized tail follows" >&2
  mask_tail "${ADMIN_SETUP_LOG}" >&2
  exit "${ADMIN_SETUP_RC}"
fi

echo "[ranger-install] harden Ranger Admin runtime config"
sudo ADMIN_HOME="${ADMIN_HOME}" NODE_IP="${NODE_IP}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET
from pathlib import Path

conf = Path(os.environ["ADMIN_HOME"]) / "ews/webapp/WEB-INF/classes/conf/ranger-admin-site.xml"
tree = ET.parse(conf)
root = tree.getroot()

updates = {
    "ranger.service.host": os.environ["NODE_IP"],
    "ranger.service.http.port": "6080",
    "ranger.service.https.port": "-1",
    "ranger.service.shutdown.port": "6085",
    "ranger.service.http.connector.property.address": os.environ["NODE_IP"],
    "ajp.enabled": "false",
}

props = {}
for prop in root.findall("property"):
    name = prop.find("name")
    if name is not None and name.text:
        props[name.text] = prop

for key, value in updates.items():
    prop = props.get(key)
    if prop is None:
        prop = ET.SubElement(root, "property")
        name = ET.SubElement(prop, "name")
        name.text = key
        val = ET.SubElement(prop, "value")
    else:
        val = prop.find("value")
        if val is None:
            val = ET.SubElement(prop, "value")
    val.text = value

tree.write(conf, encoding="utf-8", xml_declaration=True)
PY

sudo bash -c "cat > '${ADMIN_HOME}/ews/webapp/WEB-INF/classes/conf/java_home.sh'" <<EOF
export JAVA_HOME=${JAVA11_HOME}
EOF
sudo bash -c "cat > '${ADMIN_HOME}/ews/webapp/WEB-INF/classes/conf/ranger-admin-env-v2.sh'" <<EOF
export RANGER_ADMIN_LOG_DIR=${LOG_DIR}/admin
export RANGER_PID_DIR_PATH=${RUN_DIR}
export RANGER_ADMIN_PID_NAME=rangeradmin.pid
export JAVA_OPTS="\${JAVA_OPTS:-} -Dranger.service.http.connector.property.address=${NODE_IP}"
EOF

sudo chmod 640 "${ADMIN_HOME}/ews/webapp/WEB-INF/classes/conf/ranger-admin-site.xml"
sudo chown -R ranger:ranger "${DATA_DIR}" "${LOG_DIR}/admin" "${LOG_DIR}/usersync" "${RUN_DIR}"
sudo chmod 750 "${DATA_DIR}" "${LOG_DIR}/admin" "${LOG_DIR}/usersync" "${RUN_DIR}"

echo "[ranger-install] install Ranger Admin systemd unit"
sudo bash -c "cat > /etc/systemd/system/finance-ranger-admin.service" <<EOF
[Unit]
Description=Finance BigData V2 Ranger Admin
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=forking
Environment=JAVA_HOME=${JAVA11_HOME}
Environment=RANGER_ADMIN_LOG_DIR=${LOG_DIR}/admin
Environment=RANGER_PID_DIR_PATH=${RUN_DIR}
Environment=RANGER_ADMIN_PID_NAME=rangeradmin.pid
PIDFile=${RUN_DIR}/rangeradmin.pid
WorkingDirectory=${ADMIN_HOME}/ews
ExecStart=${ADMIN_HOME}/ews/ranger-admin-services.sh start
ExecStop=${ADMIN_HOME}/ews/ranger-admin-services.sh stop
Restart=on-failure
RestartSec=10
TimeoutStartSec=120
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
  echo "[ranger-install] restrict firewall access to CLUSTER_SUBNET_CIDR for 6080"
  sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="CLUSTER_SUBNET_CIDR" port protocol="tcp" port="6080" accept' >/dev/null || true
  sudo firewall-cmd --reload >/dev/null || true
fi

sudo systemctl daemon-reload
sudo systemctl enable --now finance-ranger-admin

echo "[ranger-install] wait for Ranger Admin 6080"
READY=0
for _ in $(seq 1 60); do
  if curl -fsS --max-time 3 "${ADMIN_URL}/login.jsp" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done
if [ "${READY}" -ne 1 ]; then
  echo "[ranger-install] Ranger Admin did not become ready on ${ADMIN_URL}; service status follows" >&2
  sudo systemctl status finance-ranger-admin --no-pager -l >&2 || true
  mask_tail "${LOG_DIR}/admin/catalina.out" >&2
  exit 3
fi

echo "[ranger-install] verify 6080 bind address"
SS_6080="$(ss -lntp | awk '$4 ~ /:6080$/ {print}')"
printf '%s\n' "${SS_6080}"
if printf '%s\n' "${SS_6080}" | grep -Eq '0\.0\.0\.0:6080|\[::\]:6080|\*:6080'; then
  echo "[ranger-install] unsafe 6080 bind detected; stopping Ranger Admin" >&2
  sudo systemctl stop finance-ranger-admin || true
  exit 4
fi
if ! printf '%s\n' "${SS_6080}" | grep -Eq "(${NODE_IP}:6080|\\[::ffff:${NODE_IP//./\\.}\\]:6080)"; then
  echo "[ranger-install] expected ${NODE_IP}:6080 listener not found; stopping Ranger Admin" >&2
  sudo systemctl stop finance-ranger-admin || true
  exit 5
fi

echo "[ranger-install] run Ranger UserSync setup"
USERSYNC_SETUP_LOG="${LOG_DIR}/usersync/setup.log"
sudo mkdir -p "${USERSYNC_HOME}/conf"
sudo bash -c "cat > '${USERSYNC_HOME}/conf/java_home.sh'" <<EOF
export JAVA_HOME=${JAVA11_HOME}
EOF
set +e
sudo bash -c "cd '${USERSYNC_HOME}' && export JAVA_HOME='${JAVA11_HOME}' && export PATH='${JAVA11_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' && ./setup.sh > '${USERSYNC_SETUP_LOG}' 2>&1"
USERSYNC_SETUP_RC=$?
set -e
if [ "${USERSYNC_SETUP_RC}" -ne 0 ]; then
  echo "[ranger-install] Ranger UserSync setup failed; sanitized tail follows" >&2
  mask_tail "${USERSYNC_SETUP_LOG}" >&2
  exit "${USERSYNC_SETUP_RC}"
fi

sudo bash -c "cat > '${USERSYNC_HOME}/conf/ranger-usersync-env-v2.sh'" <<EOF
export JAVA_HOME=${JAVA11_HOME}
export logdir=${LOG_DIR}/usersync
export USERSYNC_PID_DIR_PATH=${RUN_DIR}
export USERSYNC_PID_NAME=usersync.pid
EOF

echo "[ranger-install] install Ranger UserSync systemd unit"
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

echo "[ranger-install] start UserSync only if 5151 can be kept off wildcard bind"
sudo systemctl start finance-ranger-usersync || true
sleep 8
SS_5151="$(ss -lntp | awk '$4 ~ /:5151$/ {print}' || true)"
if [ -n "${SS_5151}" ]; then
  printf '%s\n' "${SS_5151}"
  if printf '%s\n' "${SS_5151}" | grep -Eq '0\.0\.0\.0:5151|\[::\]:5151|\*:5151'; then
    echo "[ranger-install] UserSync/UnixAuth uses unsafe 5151 wildcard bind; stopping UserSync and leaving it installed but disabled"
    sudo systemctl stop finance-ranger-usersync || true
    sudo systemctl disable finance-ranger-usersync >/dev/null || true
  fi
else
  echo "[ranger-install] no 5151 listener detected after UserSync start"
fi

echo "[ranger-install] final status"
systemctl is-active finance-ranger-admin
systemctl is-enabled finance-ranger-admin
curl -fsS --max-time 3 "${ADMIN_URL}/login.jsp" >/dev/null
echo "ranger_admin_url=${ADMIN_URL}"
echo "ranger_admin_home=${ADMIN_HOME}"
echo "ranger_usersync_home=${USERSYNC_HOME}"
echo "ranger_db=${RANGER_DB_NAME}"
echo "[ranger-install] done"

