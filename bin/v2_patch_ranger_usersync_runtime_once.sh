set -euo pipefail

NODE_IP="CLUSTER_NODE1_IP"
ADMIN_URL="http://${NODE_IP}:6080"
USERSYNC_HOME="/export/server/ranger-usersync"
LOG_DIR="/export/logs/ranger"
RUN_DIR="/export/run/ranger"
JAVA11_HOME="/usr/lib/jvm/java-11-openjdk"

echo "[usersync-runtime-patch] host=$(hostname) user=$(whoami)"

sudo systemctl disable --now finance-ranger-usersync 2>/dev/null || true
sudo pkill -f -- '-[D]proc_rangerusersync' 2>/dev/null || true

sudo cp -f /export/maven_repo/org/apache/ranger/ranger-common-ha/2.6.0/ranger-common-ha-2.6.0.jar "${USERSYNC_HOME}/lib/"
sudo mkdir -p "${USERSYNC_HOME}/conf" "${LOG_DIR}/usersync" "${RUN_DIR}"
sudo cp -f "${USERSYNC_HOME}/conf.dist/logback.xml" "${USERSYNC_HOME}/conf/logback.xml"

sudo bash -c "cat > '${USERSYNC_HOME}/conf/ranger-ugsync-site.xml'" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
  <property>
    <name>ranger.usersync.enabled</name>
    <value>true</value>
  </property>
  <property>
    <name>ranger.usersync.port</name>
    <value>5151</value>
  </property>
  <property>
    <name>ranger.usersync.ssl</name>
    <value>false</value>
  </property>
  <property>
    <name>ranger.usersync.policymanager.baseURL</name>
    <value>${ADMIN_URL}</value>
  </property>
  <property>
    <name>ranger.usersync.policymanager.maxrecordsperapicall</name>
    <value>1000</value>
  </property>
  <property>
    <name>ranger.usersync.policymanager.mockrun</name>
    <value>false</value>
  </property>
  <property>
    <name>ranger.usersync.source.impl.class</name>
    <value>org.apache.ranger.unixusersync.process.UnixUserGroupBuilder</value>
  </property>
  <property>
    <name>ranger.usersync.sink.impl.class</name>
    <value>org.apache.ranger.unixusersync.process.PolicyMgrUserGroupBuilder</value>
  </property>
  <property>
    <name>ranger.usersync.unix.minUserId</name>
    <value>500</value>
  </property>
  <property>
    <name>ranger.usersync.unix.minGroupId</name>
    <value>500</value>
  </property>
  <property>
    <name>ranger.usersync.logdir</name>
    <value>${LOG_DIR}/usersync</value>
  </property>
  <property>
    <name>ranger.usersync.credstore.filename</name>
    <value>/etc/ranger/usersync/conf/rangerusersync.jceks</value>
  </property>
</configuration>
EOF

sudo bash -c "cat > '${USERSYNC_HOME}/conf/java_home.sh'" <<EOF
export JAVA_HOME=${JAVA11_HOME}
EOF
sudo bash -c "cat > '${USERSYNC_HOME}/conf/ranger-usersync-env-v2.sh'" <<EOF
export JAVA_HOME=${JAVA11_HOME}
export HADOOP_HOME=/export/server/hadoop
export hadoop_home=/export/server/hadoop
export logdir=${LOG_DIR}/usersync
export USERSYNC_PID_DIR_PATH=${RUN_DIR}
export USERSYNC_PID_NAME=usersync.pid
EOF

sudo chown -R ranger:ranger "${USERSYNC_HOME}/conf" "${LOG_DIR}/usersync" "${RUN_DIR}"

sudo systemctl daemon-reload
sudo systemctl reset-failed finance-ranger-usersync || true
sudo systemctl start finance-ranger-usersync || true
sleep 8

echo "[usersync-runtime-patch] status"
systemctl is-active finance-ranger-usersync || true
systemctl is-enabled finance-ranger-usersync || true
SS_5151="$(ss -lntp | awk '$4 ~ /:5151$/ {print}' || true)"
if [ -n "${SS_5151}" ]; then
  printf '%s\n' "${SS_5151}"
  if printf '%s\n' "${SS_5151}" | grep -Eq '0\.0\.0\.0:5151|\[::\]:5151|\*:5151'; then
    echo "[usersync-runtime-patch] unsafe 5151 wildcard bind; stopping and disabling usersync"
    sudo systemctl disable --now finance-ranger-usersync || true
  fi
fi

echo "[usersync-runtime-patch] admin"
systemctl is-active finance-ranger-admin
ss -lntp | awk '$4 ~ /:6080$/ {print}'
echo "[usersync-runtime-patch] done"

