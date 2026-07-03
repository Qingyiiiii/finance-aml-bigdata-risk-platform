#!/usr/bin/env bash
set -uo pipefail

echo "FAST_PROBE_START $(date '+%Y-%m-%d %H:%M:%S') host=$(hostname)"

echo "systemd_clickhouse=$(systemctl is-active clickhouse-server 2>/dev/null || true)"
echo "systemd_elasticsearch=$(systemctl is-active elasticsearch-finance-v2 2>/dev/null || true)"
echo "systemd_ranger=$(systemctl is-active finance-ranger-admin 2>/dev/null || true)"
echo "systemd_atlas=$(systemctl is-active finance-atlas 2>/dev/null || true)"

echo "ports_begin"
ss -lntp 2>/dev/null | awk '$4 ~ /:(8080|18080|2181|2182|3000|6080|8123|9000|9090|9200|9300|9838)$/ {print}'
echo "ports_end"

echo "jps_begin"
jps -l 2>/dev/null | awk '/HMaster|HRegionServer|QuorumPeerMain|StandaloneSessionClusterEntrypoint|TaskManagerRunner|kafka.Kafka|NameNode|ResourceManager/ {print}'
echo "jps_end"

echo "monitor_processes_begin"
ps -eo pid,comm,args --no-headers 2>/dev/null | awk '/\/export\/server\/prometheus\/prometheus|\/export\/server\/grafana\/bin\/grafana/ && !/awk/ {print}'
echo "monitor_processes_end"

printf 'prometheus_ready_code='
timeout 6s curl -sS -o /tmp/p15v2_fast_prometheus.out -w '%{http_code}' --max-time 4 http://CLUSTER_NODE1_IP:9090/-/ready 2>/tmp/p15v2_fast_prometheus.err || true
echo
printf 'grafana_login_code='
timeout 6s curl -sS -o /tmp/p15v2_fast_grafana.out -w '%{http_code}' --max-time 4 http://CLUSTER_NODE1_IP:3000/login 2>/tmp/p15v2_fast_grafana.err || true
echo

echo "trino_local_status_begin"
timeout 8s bash -lc 'export JAVA_HOME=/export/server/jdk25; /export/server/trino/bin/launcher status' 2>&1 || true
echo "trino_local_status_end"

echo "FAST_PROBE_END $(date '+%Y-%m-%d %H:%M:%S')"
exit 0

