#!/usr/bin/env bash
# Purpose: Spark SQL 最小烟测脚本，只验证 spark-sql 能启动并执行简单 SQL。
# Boundary: 不读取 finance_bigdata 表，不代表 P5/P14 已通过。
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
  -e "SHOW DATABASES; SELECT 1 AS spark_smoke;"
