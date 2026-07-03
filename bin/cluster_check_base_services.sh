#!/usr/bin/env bash
# Purpose: 基础服务人工排查脚本，快速打印主机、JPS、端口、HDFS/YARN/Hive 状态。
# Boundary: 这是只读检查脚本，不启动服务、不修改 finance_bigdata 表。
set -u

source /etc/profile.d/bigdata.sh 2>/dev/null || true
echo "===== host ====="
hostname
whoami
free -h
df -h /export

echo "===== jps ====="
jps -l || true

echo "===== ports ====="
ss -lntp | egrep '8020|9870|8088|9083|10000|5432|6379|8081|18030|9030|9050|8080|12345|9090|3000' || true

echo "===== hdfs ====="
timeout 20s hdfs dfs -ls / || true

echo "===== yarn ====="
timeout 20s yarn node -list || true
timeout 20s yarn application -list -appStates RUNNING || true

echo "===== hive ====="
timeout 45s /export/server/hive/bin/beeline -u "jdbc:hive2://hadoop1:10000/default" -n common -e "SHOW DATABASES;" || true
