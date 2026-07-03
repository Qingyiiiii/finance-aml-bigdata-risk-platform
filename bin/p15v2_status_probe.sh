#!/usr/bin/env bash
set -uo pipefail

echo "PROBE_START $(date '+%Y-%m-%d %H:%M:%S') host=$(hostname)"

echo "===== ports ====="
ss -lntp 2>/dev/null | awk '$4 ~ /:(8080|2181|2182|3000|6080|8123|9000|9090|9200|9300|9838)$/ {print}' || true

echo "===== jps-local ====="
jps -l 2>/dev/null | egrep 'HMaster|HRegionServer|QuorumPeerMain|StandaloneSessionClusterEntrypoint|TaskManagerRunner|kafka.Kafka|trino|NameNode|ResourceManager' || true

echo "===== systemd ====="
for svc in clickhouse-server elasticsearch-finance-v2 finance-ranger-admin finance-atlas; do
  printf '%s=' "$svc"
  systemctl is-active "$svc" 2>/dev/null || true
done

echo "===== hbase-nodes ====="
for host in hadoop1 hadoop2 hadoop3; do
  echo "--- ${host} ---"
  timeout 8s ssh -o ConnectTimeout=3 -n common@"$host" "jps -l | egrep 'HMaster|HRegionServer|QuorumPeerMain' || true; /export/server/zookeeper/bin/zkServer.sh status || true" 2>&1 || true
done

echo "===== hbase-shell ====="
timeout 25s /export/server/hbase/bin/hbase shell -n 2>&1 <<'HBASE' | sed -n '1,80p'
status 'simple'
exists 'finance_bigdata_v2:account_risk_state'
HBASE

echo "===== prometheus-grafana ====="
pgrep -af '/export/server/prometheus/prometheus|/export/server/grafana' || true
printf 'prometheus_ready_code='
curl -sS -o /tmp/p15v2_probe_prometheus.out -w '%{http_code}' --max-time 5 http://CLUSTER_NODE1_IP:9090/-/ready 2>/tmp/p15v2_probe_prometheus.err || true
echo
printf 'grafana_login_code='
curl -sS -o /tmp/p15v2_probe_grafana.out -w '%{http_code}' --max-time 5 http://CLUSTER_NODE1_IP:3000/login 2>/tmp/p15v2_probe_grafana.err || true
echo

echo "===== trino ====="
for host in hadoop1 hadoop2 hadoop3; do
  echo "--- ${host} ---"
  timeout 8s ssh -o ConnectTimeout=3 -n common@"$host" "export JAVA_HOME=/export/server/jdk25; /export/server/trino/bin/launcher status || true; ss -lntp | grep ':8080' || true" 2>&1 || true
done

echo "PROBE_END $(date '+%Y-%m-%d %H:%M:%S')"

