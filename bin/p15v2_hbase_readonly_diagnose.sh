#!/usr/bin/env bash
# Read-only HBase/ZooKeeper diagnosis for P15v2 service repair.
set -uo pipefail

REMOTE_ROOT=${REMOTE_ROOT:-/home/common/tmp/finance_bigdata_project}
REPAIR_NAME=${REPAIR_NAME:-p15v2_service_repair_20260703_015213}
RUN_DIR="$REMOTE_ROOT/runs/$REPAIR_NAME"
mkdir -p "$RUN_DIR"

export JAVA_HOME=${JAVA_HOME:-/export/server/jdk17}
export PATH=/export/server/hadoop/bin:/export/server/hadoop/sbin:/export/server/hbase/bin:/export/server/zookeeper/bin:$JAVA_HOME/bin:$PATH

status_file="$RUN_DIR/hbase_readonly_diagnosis.tsv"
echo -e "check\tstatus\tdetail" > "$status_file"

record() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$status_file"
}

run_capture() {
  local name="$1"
  shift
  local out="$RUN_DIR/${name}.out"
  if timeout 20 "$@" > "$out" 2>&1; then
    record "$name" "PASS" "$out"
  else
    record "$name" "FAIL" "$out"
  fi
}

ssh_capture() {
  local host="$1"
  local name="$2"
  local command="$3"
  local out="$RUN_DIR/${name}_${host}.out"
  if timeout 12 ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=no "common@$host" "$command" > "$out" 2>&1; then
    record "${name}_${host}" "PASS" "$out"
  else
    record "${name}_${host}" "FAIL" "$out"
  fi
}

for host in hadoop1 hadoop2 hadoop3; do
  if [ "$host" = "$(hostname -s)" ]; then
    run_capture "zk_status_${host}" /export/server/zookeeper/bin/zkServer.sh status
    run_capture "jps_${host}" jps -l
  else
    ssh_capture "$host" "zk_status" "/export/server/zookeeper/bin/zkServer.sh status"
    ssh_capture "$host" "jps" "jps -l"
  fi
done

run_capture "hbase_local_recent_errors" bash -lc "ls -1t /export/server/hbase/logs/* 2>/dev/null | head -n 6 | xargs -r grep -HEn 'ERROR|Exception|KeeperError|NoNode|master' | tail -n 120"
run_capture "hdfs_hbase_root_ls" hdfs dfs -ls /lakehouse/services/hbase
run_capture "hbase_status_simple" bash -lc "printf \"status 'simple'\n\" | hbase shell -n"
run_capture "hbase_namespace_finance_bigdata_v2" bash -lc "printf \"list_namespace\n\" | hbase shell -n | grep -F 'finance_bigdata_v2'"
run_capture "hbase_table_account_risk_state" bash -lc "printf \"exists 'finance_bigdata_v2:account_risk_state'\n\" | hbase shell -n"
run_capture "hbase_scan_account_risk_state_one" bash -lc "printf \"scan 'finance_bigdata_v2:account_risk_state', {LIMIT => 1}\n\" | hbase shell -n"

echo "P15V2_HBASE_READONLY_REMOTE_DIR=$RUN_DIR"
