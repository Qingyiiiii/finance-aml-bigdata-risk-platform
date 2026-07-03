#!/usr/bin/env bash
# Repair and verify HBase Master for P15v2 without rewriting business data.
set -uo pipefail

REMOTE_ROOT=${REMOTE_ROOT:-/home/common/tmp/finance_bigdata_project}
REPAIR_NAME=${REPAIR_NAME:-p15v2_service_repair_20260703_015213}
RUN_DIR="$REMOTE_ROOT/runs/$REPAIR_NAME"
mkdir -p "$RUN_DIR"

export JAVA_HOME=/export/server/jdk17
export PATH=/export/server/hadoop/bin:/export/server/hadoop/sbin:/export/server/hbase/bin:/export/server/zookeeper/bin:$JAVA_HOME/bin:$PATH

status="$RUN_DIR/hbase_master_repair.tsv"
echo -e "check\tstatus\tdetail" > "$status"

record() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$status"
}

capture() {
  local name="$1"
  shift
  local out="$RUN_DIR/${name}.out"
  if timeout 45 "$@" > "$out" 2>&1; then
    record "$name" "PASS" "$out"
  else
    record "$name" "FAIL" "$out"
  fi
}

capture zk_status /export/server/zookeeper/bin/zkServer.sh status
capture hdfs_hbase_root_ls hdfs dfs -ls /lakehouse/services/hbase

if ! jps -l | grep -q 'org.apache.hadoop.hbase.master.HMaster'; then
  capture start_hbase_master /export/server/hbase/bin/hbase-daemon.sh start master
else
  echo "HMaster already running" > "$RUN_DIR/start_hbase_master.out"
  record start_hbase_master PASS "$RUN_DIR/start_hbase_master.out"
fi

if ! jps -l | grep -q 'org.apache.hadoop.hbase.regionserver.HRegionServer'; then
  capture start_hbase_regionserver /export/server/hbase/bin/hbase-daemon.sh start regionserver
else
  echo "HRegionServer already running on hadoop1" > "$RUN_DIR/start_hbase_regionserver.out"
  record start_hbase_regionserver PASS "$RUN_DIR/start_hbase_regionserver.out"
fi

sleep 20

capture hbase_processes bash -lc "jps -l | egrep 'HMaster|HRegionServer|QuorumPeerMain|Jps' || true"
capture hbase_ports bash -lc "ss -lntp | egrep ':(16000|16010|16020|16030|2181)\\b' || true"
capture hbase_status_simple bash -lc "printf \"status 'simple'\n\" | /export/server/hbase/bin/hbase shell -n"
capture hbase_namespace_finance_bigdata_v2 bash -lc "printf \"list_namespace\n\" | /export/server/hbase/bin/hbase shell -n | grep -F 'finance_bigdata_v2'"
capture hbase_table_account_risk_state bash -lc "printf \"exists 'finance_bigdata_v2:account_risk_state'\n\" | /export/server/hbase/bin/hbase shell -n"
capture hbase_scan_account_risk_state_one bash -lc "printf \"scan 'finance_bigdata_v2:account_risk_state', {LIMIT => 1}\n\" | /export/server/hbase/bin/hbase shell -n"

echo "P15V2_HBASE_MASTER_REPAIR_REMOTE_DIR=$RUN_DIR"
