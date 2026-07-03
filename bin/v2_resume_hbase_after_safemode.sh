set -euo pipefail

if [ -f /etc/profile.d/bigdata.sh ]; then
  source /etc/profile.d/bigdata.sh
fi

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10"

echo "[resume-hbase] host=$(hostname) user=$(whoami)"

echo "[hdfs] wait/check safemode"
for i in $(seq 1 12); do
  status=$(hdfs dfsadmin -safemode get 2>&1 || true)
  echo "attempt=$i $status"
  if echo "$status" | grep -qi 'Safe mode is OFF'; then
    break
  fi
  sleep 5
done

if hdfs dfsadmin -safemode get 2>&1 | grep -qi 'Safe mode is ON'; then
  echo "[hdfs] leaving safemode for V2 HBase service directory creation"
  hdfs dfsadmin -safemode leave
fi

hdfs dfs -mkdir -p /lakehouse/services/hbase
hdfs dfs -chown -R common:supergroup /lakehouse/services/hbase
hdfs dfs -chmod -R 775 /lakehouse/services/hbase
hdfs dfs -ls /lakehouse/services

echo "[hbase] config sanity"
for h in hadoop1 hadoop2 hadoop3; do
  echo "===== $h hbase config ====="
  ssh $SSH_OPTS common@$h "readlink -f /export/server/hbase; grep -nE 'hbase.rootdir|hbase.zookeeper.quorum|hbase.master.hostname|hbase.master.info.bindAddress|hbase.regionserver.hostname|hbase.regionserver.info.bindAddress' /export/server/hbase/conf/hbase-site.xml"
done

echo "[hbase] restart"
/export/server/hbase/bin/stop-hbase.sh >/dev/null 2>&1 || true
sleep 5
/export/server/hbase/bin/start-hbase.sh
sleep 25

echo "[hbase] namespace validation"
/export/server/hbase/bin/hbase shell <<'HBASE'
status
begin
  create_namespace 'finance_bigdata_v2'
rescue Exception => e
  puts e.message
end
list_namespace
HBASE

echo "[hbase] ports and processes"
for h in hadoop1 hadoop2 hadoop3; do
  echo "===== hbase $h ====="
  ssh $SSH_OPTS common@$h "jps | sort; ss -lntp | egrep '16000|16010|16020|16030' || true"
done
