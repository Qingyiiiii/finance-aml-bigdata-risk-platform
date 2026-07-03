#!/usr/bin/env bash
# Purpose: 实时服务只读检查脚本，查看 Kafka、Redis、Flink 和 YARN 实时状态。
# Boundary: 不创建 topic、不提交 Flink 作业、不写 Redis key。
set -u

export JAVA_HOME=/export/server/jdk17
export PATH=$JAVA_HOME/bin:/export/server/kafka/bin:/export/server/flink/bin:$PATH

echo "===== kafka quorum ====="
/export/server/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server CLUSTER_NODE1_IP:9092 describe --status

echo "===== kafka topics ====="
/export/server/kafka/bin/kafka-topics.sh --bootstrap-server CLUSTER_NODE1_IP:9092 --list

echo "===== redis ====="
redis-cli -h 127.0.0.1 ping

echo "===== flink ====="
jps -l | egrep 'StandaloneSessionClusterEntrypoint|TaskManagerRunner' || true
ss -lntp | egrep '8081|9092|9093|6379' || true
curl -I --max-time 10 http://hadoop1:8081 || true
/export/server/flink/bin/flink list -r || true

echo "===== yarn running ====="
timeout 20s yarn application -list -appStates RUNNING || true

