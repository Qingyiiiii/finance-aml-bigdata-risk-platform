#!/usr/bin/env bash
# Purpose: P5 发布后的快速复核脚本，检查 Iceberg 表可见性和 YARN 残留。
# Boundary: 只做 postcheck，不重新发布表，也不修改数据。
set -u

source /etc/profile.d/bigdata.sh 2>/dev/null || true
export JAVA_HOME=/export/server/jdk17
export PATH=/export/server/spark/bin:/export/server/hadoop/bin:/export/server/hadoop/sbin:$JAVA_HOME/bin:$PATH

spark-sql \
  --conf spark.executor.instances=1 \
  --conf spark.executor.cores=1 \
  --conf spark.executor.memory=512m \
  --conf spark.executor.memoryOverhead=256m \
  --conf spark.driver.memory=512m \
  --conf spark.driver.bindAddress=0.0.0.0 \
  --conf spark.driver.host=hadoop1 \
  --conf spark.driver.port=37101 \
  --conf spark.blockManager.port=37102 \
  --conf spark.sql.shuffle.partitions=2 \
  -e "SHOW TABLES IN lakehouse.finance_bigdata;"

timeout 20s yarn application -list -appStates RUNNING
