#!/usr/bin/env bash
# Read-only hadoop1 base service and port probe for P15v2 service repair.
set -uo pipefail

REMOTE_ROOT=${REMOTE_ROOT:-/home/common/tmp/finance_bigdata_project}
REPAIR_NAME=${REPAIR_NAME:-p15v2_service_repair_20260703_015213}
RUN_DIR="$REMOTE_ROOT/runs/$REPAIR_NAME"
mkdir -p "$RUN_DIR"

export JAVA17_HOME=/export/server/jdk17
export JAVA25_HOME=/export/server/jdk25
export PATH=/usr/local/bin:/usr/bin:/bin:/export/server/hadoop/bin:/export/server/hadoop/sbin:/export/server/hive/bin:/export/server/flink/bin:/export/server/hbase/bin:/export/server/zookeeper/bin:$JAVA17_HOME/bin:$PATH

status="$RUN_DIR/hadoop1_base_probe.tsv"
echo -e "check\tstatus\tdetail" > "$status"

record() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$status"
}

capture() {
  local name="$1"
  shift
  local out="$RUN_DIR/${name}.out"
  if timeout 20 "$@" > "$out" 2>&1; then
    record "$name" "PASS" "$out"
  else
    record "$name" "FAIL" "$out"
  fi
}

capture hostname hostname
capture date date "+%F_%T"
capture uptime uptime
capture jps jps -l
capture port_snapshot bash -lc "ss -lntp | egrep ':(22|8020|8032|8088|9870|9083|10000|2181|8123|9000|9200|9300|6080|21000|8081|16000|16010|8080|18080|9090|3000)\\b' || true"
capture sshd_status bash -lc "systemctl is-active sshd 2>/dev/null || systemctl is-active ssh 2>/dev/null || true"
capture clickhouse_status systemctl is-active clickhouse-server
capture elasticsearch_status systemctl is-active elasticsearch-finance-v2
capture ranger_status systemctl is-active finance-ranger-admin
capture atlas_status systemctl is-active finance-atlas
capture zookeeper_status /export/server/zookeeper/bin/zkServer.sh status
capture hdfs_report hdfs dfsadmin -report
capture yarn_nodes yarn node -list
capture hive_metastore_port bash -lc "ss -lntp | grep ':9083' || true"
capture flink_jobs /export/server/flink/bin/flink list -r

echo "P15V2_HADOOP1_BASE_PROBE_REMOTE_DIR=$RUN_DIR"
