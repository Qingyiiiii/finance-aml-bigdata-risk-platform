#!/usr/bin/env bash
# Purpose: 启动 Kafka、Redis、Flink 三类实时服务，供 P6/P11 实时闭环使用。
# Boundary: 仅启动服务，不创建 topic，不提交 Flink SQL。
set -u

export JAVA_HOME=/export/server/jdk17
export PATH=$JAVA_HOME/bin:/export/server/kafka/bin:/export/server/flink/bin:$PATH

echo "===== start kafka ====="
for host in hadoop1 hadoop2 hadoop3; do
  ssh -n common@$host "bash -lc '
    export JAVA_HOME=/export/server/jdk17
    export PATH=\$JAVA_HOME/bin:\$PATH
    if jps -l | grep -q \"kafka.Kafka\"; then
      echo kafka already running on $host
    else
      mkdir -p /export/logs/kafka
      setsid /export/server/kafka/bin/kafka-server-start.sh /export/server/kafka/config/kraft/server.properties > /export/logs/kafka/kafka-server.out 2>&1 < /dev/null &
      echo kafka start submitted on $host
    fi
  '"
done
sleep 25

echo "===== start redis ====="
if systemctl is-active --quiet redis; then
  echo "redis already running"
else
  sudo -S -p '' systemctl start redis
fi

echo "===== start flink ====="
if jps -l | grep -q 'org.apache.flink.runtime.entrypoint.StandaloneSessionClusterEntrypoint'; then
  echo "flink jobmanager already running"
else
  /export/server/flink/bin/start-cluster.sh
fi
sleep 10

echo "===== realtime processes ====="
for host in hadoop1 hadoop2 hadoop3; do
  echo "----- $host -----"
  ssh -n common@$host "jps -l | egrep 'kafka.Kafka|StandaloneSessionClusterEntrypoint|TaskManagerRunner' || true; ss -lntp | egrep '9092|9093|8081|6379' || true"
done
