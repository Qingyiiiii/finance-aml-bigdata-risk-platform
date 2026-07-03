#!/usr/bin/env bash
# Purpose: 启动 Hive Metastore 和 HiveServer2，供 Spark/Iceberg/Beeline 查询使用。
# Boundary: 只负责 Hive 服务恢复，不创建 finance_bigdata 表。
set -u

echo "===== cleanup old hive processes ====="
jps -l | awk '/org.apache.hive.service.server.HiveServer2|org.apache.hadoop.hive.metastore.HiveMetaStore/ {print $1}' | xargs -r kill 2>/dev/null || true
sleep 2

echo "===== start hive metastore and hiveserver2 ====="
export JAVA_HOME=/export/server/jdk8
export PATH=$JAVA_HOME/bin:/export/server/hive/bin:/export/server/hadoop/bin:/export/server/hadoop/sbin:$PATH
export HADOOP_HOME=/export/server/hadoop
export HIVE_HOME=/export/server/hive
export HADOOP_CONF_DIR=/export/server/hive/conf/hadoop-conf-jdk8
export YARN_CONF_DIR=/export/server/hive/conf/hadoop-conf-jdk8
export HIVE_CONF_DIR=/export/server/hive/conf

mkdir -p /export/logs/hive
HADOOP_CP=$(JAVA_HOME=/export/server/jdk8 /export/server/hadoop/bin/hadoop --config /export/server/hive/conf/hadoop-conf-jdk8 classpath --glob)
HIVE_CP="/export/server/hive/conf:/export/server/hive/conf/hadoop-conf-jdk8:/export/server/hive/lib/*:${HADOOP_CP}"

nohup /export/server/jdk8/bin/java -Xmx512m -Dhive.log.dir=/export/logs/hive -Dhive.log.file=hive-metastore.log -Dhadoop.log.dir=/export/logs/hive -Dhadoop.log.file=hive-metastore.log -cp "$HIVE_CP" org.apache.hadoop.hive.metastore.HiveMetaStore > /export/logs/hive/hive-metastore.out 2>&1 &
sleep 10
nohup /export/server/jdk8/bin/java -Xmx512m -Dhive.log.dir=/export/logs/hive -Dhive.log.file=hiveserver2.log -Dhadoop.log.dir=/export/logs/hive -Dhadoop.log.file=hiveserver2.log -cp "$HIVE_CP" org.apache.hive.service.server.HiveServer2 > /export/logs/hive/hiveserver2.out 2>&1 &
sleep 15

echo "===== check hive ====="
jps -l | egrep 'HiveMetaStore|HiveServer2' || true
ss -lntp | egrep '9083|10000' || true
timeout 45s /export/server/hive/bin/beeline -u "jdbc:hive2://hadoop1:10000/default" -n common -e "SHOW DATABASES;"
