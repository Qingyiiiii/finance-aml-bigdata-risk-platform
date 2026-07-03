#!/usr/bin/env bash
# Purpose: 启动 HDFS/YARN 基础服务，并做最小可用性检查。
# Boundary: 只处理集群基础服务，不发布 finance_bigdata 表，也不运行 P14。
set -u

source /etc/profile.d/bigdata.sh 2>/dev/null || true
export JAVA_HOME=/export/server/jdk17
export PATH=/export/server/hadoop/bin:/export/server/hadoop/sbin:$JAVA_HOME/bin:$PATH

echo "===== start hdfs yarn ====="
start-dfs.sh
start-yarn.sh

echo "===== check hdfs yarn ====="
jps -l
timeout 20s hdfs dfs -ls /
timeout 20s yarn node -list
ss -lntp | egrep '8020|9870|8088|8042' || true
