set -euo pipefail

if [ -f /etc/profile.d/bigdata.sh ]; then
  source /etc/profile.d/bigdata.sh
fi

ZK_VERSION=3.9.5
HBASE_VERSION=2.6.6
ZK_TGZ="apache-zookeeper-${ZK_VERSION}-bin.tar.gz"
HBASE_TGZ="hbase-${HBASE_VERSION}-hadoop3-bin.tar.gz"
ZK_URL="https://downloads.apache.org/zookeeper/zookeeper-${ZK_VERSION}/${ZK_TGZ}"
HBASE_URL="https://downloads.apache.org/hbase/${HBASE_VERSION}/${HBASE_TGZ}"

declare -A HOST_IPS=(
  [hadoop1]=CLUSTER_NODE1_IP
  [hadoop2]=CLUSTER_NODE2_IP
  [hadoop3]=CLUSTER_NODE3_IP
)

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10"

echo "[zk-hbase] host=$(hostname) user=$(whoami)"

download_if_missing() {
  local url="$1"
  local file="/export/packages/$2"
  if [ -s "$file" ]; then
    echo "[download] exists $file"
    return 0
  fi
  echo "[download] $url"
  curl -fL --retry 3 --retry-delay 5 "$url" -o "$file"
}

download_if_missing "$ZK_URL" "$ZK_TGZ"
download_if_missing "$HBASE_URL" "$HBASE_TGZ"

echo "[firewall] opening V2 state ports on all nodes"
for h in hadoop1 hadoop2 hadoop3; do
  ssh $SSH_OPTS common@$h "for p in 2181 2888 3888 16000 16010 16020 16030; do sudo firewall-cmd --permanent --add-port=\${p}/tcp >/dev/null; done; sudo firewall-cmd --reload >/dev/null"
done

echo "[zookeeper] extract on hadoop1"
cd /export/packages
if [ ! -d "/export/server/apache-zookeeper-${ZK_VERSION}-bin" ]; then
  tar -xzf "$ZK_TGZ" -C /export/server
fi
ln -sfn "/export/server/apache-zookeeper-${ZK_VERSION}-bin" /export/server/zookeeper
mkdir -p /export/data/zookeeper /export/logs/zookeeper
chown -R common:common "/export/server/apache-zookeeper-${ZK_VERSION}-bin" /export/data/zookeeper /export/logs/zookeeper
chown -h common:common /export/server/zookeeper

cat > /tmp/zoo.cfg.template <<'EOF'
tickTime=2000
initLimit=10
syncLimit=5
dataDir=/export/data/zookeeper
dataLogDir=/export/logs/zookeeper
clientPort=2181
clientPortAddress=__CLIENT_IP__
server.1=hadoop1:2888:3888
server.2=hadoop2:2888:3888
server.3=hadoop3:2888:3888
admin.enableServer=false
EOF

ZK_REAL_DIR=$(readlink -f /export/server/zookeeper)
ZK_REAL_NAME=$(basename "$ZK_REAL_DIR")
for h in hadoop2 hadoop3; do
  rsync -az "$ZK_REAL_DIR/" common@$h:/export/server/"$ZK_REAL_NAME"/
  ssh $SSH_OPTS common@$h "ln -sfn /export/server/$ZK_REAL_NAME /export/server/zookeeper && mkdir -p /export/data/zookeeper /export/logs/zookeeper && chown -R common:common /export/server/$ZK_REAL_NAME /export/data/zookeeper /export/logs/zookeeper && chown -h common:common /export/server/zookeeper"
done

for h in hadoop1 hadoop2 hadoop3; do
  ip="${HOST_IPS[$h]}"
  id="${h#hadoop}"
  sed "s/__CLIENT_IP__/$ip/g" /tmp/zoo.cfg.template > /tmp/zoo.$h.cfg
  scp /tmp/zoo.$h.cfg common@$h:/export/server/zookeeper/conf/zoo.cfg
  ssh $SSH_OPTS common@$h "echo $id > /export/data/zookeeper/myid"
done

echo "[zookeeper] restart"
for h in hadoop1 hadoop2 hadoop3; do
  ssh $SSH_OPTS common@$h "/export/server/zookeeper/bin/zkServer.sh stop >/dev/null 2>&1 || true"
done
for h in hadoop1 hadoop2 hadoop3; do
  ssh $SSH_OPTS common@$h "/export/server/zookeeper/bin/zkServer.sh start"
done
sleep 8
for h in hadoop1 hadoop2 hadoop3; do
  echo "===== zk $h ====="
  ssh $SSH_OPTS common@$h "/export/server/zookeeper/bin/zkServer.sh status; ss -lntp | grep 2181 || true"
done

echo "[hbase] extract on hadoop1"
cd /export/packages
if [ ! -d "/export/server/hbase-${HBASE_VERSION}-hadoop3" ]; then
  tar -xzf "$HBASE_TGZ" -C /export/server
fi
ln -sfn "/export/server/hbase-${HBASE_VERSION}-hadoop3" /export/server/hbase
mkdir -p /export/data/hbase /export/logs/hbase
chown -R common:common "/export/server/hbase-${HBASE_VERSION}-hadoop3" /export/data/hbase /export/logs/hbase
chown -h common:common /export/server/hbase

cat > /export/server/hbase/conf/hbase-env.sh <<'EOF'
export JAVA_HOME=/export/server/jdk17
export HBASE_MANAGES_ZK=false
export HBASE_LOG_DIR=/export/logs/hbase
export HBASE_PID_DIR=/export/data/hbase
EOF

cat > /export/server/hbase/conf/regionservers <<'EOF'
hadoop1
hadoop2
hadoop3
EOF

cat > /export/server/hbase/conf/hbase-site.xml <<'EOF'
<configuration>
  <property>
    <name>hbase.cluster.distributed</name>
    <value>true</value>
  </property>
  <property>
    <name>hbase.rootdir</name>
    <value>hdfs://hadoop1:8020/lakehouse/services/hbase</value>
  </property>
  <property>
    <name>hbase.zookeeper.quorum</name>
    <value>hadoop1,hadoop2,hadoop3</value>
  </property>
  <property>
    <name>hbase.zookeeper.property.clientPort</name>
    <value>2181</value>
  </property>
  <property>
    <name>hbase.master.hostname</name>
    <value>hadoop1</value>
  </property>
  <property>
    <name>hbase.master.info.bindAddress</name>
    <value>CLUSTER_NODE1_IP</value>
  </property>
  <property>
    <name>hbase.tmp.dir</name>
    <value>/export/data/hbase/tmp</value>
  </property>
</configuration>
EOF

HBASE_REAL_DIR=$(readlink -f /export/server/hbase)
HBASE_REAL_NAME=$(basename "$HBASE_REAL_DIR")
for h in hadoop2 hadoop3; do
  rsync -az "$HBASE_REAL_DIR/" common@$h:/export/server/"$HBASE_REAL_NAME"/
  ssh $SSH_OPTS common@$h "ln -sfn /export/server/$HBASE_REAL_NAME /export/server/hbase && mkdir -p /export/data/hbase /export/logs/hbase && chown -R common:common /export/server/$HBASE_REAL_NAME /export/data/hbase /export/logs/hbase && chown -h common:common /export/server/hbase"
done

for h in hadoop1 hadoop2 hadoop3; do
  ip="${HOST_IPS[$h]}"
  ssh $SSH_OPTS common@$h "python3 - <<PY
from pathlib import Path
p = Path('/export/server/hbase/conf/hbase-site.xml')
s = p.read_text()
insert = '''  <property>
    <name>hbase.regionserver.hostname</name>
    <value>$h</value>
  </property>
  <property>
    <name>hbase.regionserver.info.bindAddress</name>
    <value>$ip</value>
  </property>
'''
if 'hbase.regionserver.hostname' not in s:
    s = s.replace('  <property>\\n    <name>hbase.tmp.dir</name>', insert + '  <property>\\n    <name>hbase.tmp.dir</name>')
p.write_text(s)
PY"
done

echo "[hdfs] ensure running"
if ! timeout 20s hdfs dfs -ls / >/dev/null 2>&1; then
  echo "[hdfs] starting dfs"
  /export/server/hadoop/sbin/start-dfs.sh
  sleep 10
fi
hdfs dfs -mkdir -p /lakehouse/services/hbase
hdfs dfs -chown -R common:supergroup /lakehouse/services/hbase
hdfs dfs -chmod -R 775 /lakehouse/services/hbase

echo "[hbase] restart"
/export/server/hbase/bin/stop-hbase.sh >/dev/null 2>&1 || true
sleep 5
/export/server/hbase/bin/start-hbase.sh
sleep 15

echo "[hbase] validation"
jps | sort
/export/server/hbase/bin/hbase shell <<'HBASE'
status
create_namespace 'finance_bigdata_v2'
list_namespace
HBASE

echo "[hbase] ports"
for h in hadoop1 hadoop2 hadoop3; do
  echo "===== hbase $h ====="
  ssh $SSH_OPTS common@$h "jps | sort; ss -lntp | egrep '16000|16010|16020|16030' || true"
done

