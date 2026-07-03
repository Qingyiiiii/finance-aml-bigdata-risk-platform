#!/usr/bin/env bash
set -uo pipefail

mkdir -p /export/data/prometheus

cat > /export/server/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["CLUSTER_NODE1_IP:9090"]
        labels:
          project: "finance_bigdata_v2"
          component: "prometheus"

  - job_name: "finance_bigdata_v2_grafana"
    metrics_path: "/metrics"
    static_configs:
      - targets: ["CLUSTER_NODE1_IP:3000"]
        labels:
          project: "finance_bigdata_v2"
          component: "grafana"
EOF

if ! curl -fsS --max-time 4 http://CLUSTER_NODE1_IP:9090/-/ready >/tmp/p15v2_prometheus_precheck.out 2>/tmp/p15v2_prometheus_precheck.err; then
  pgrep -f '/export/server/prometheus/prometheus' | xargs -r kill 2>/dev/null || true
  sleep 2
  nohup /export/server/prometheus/prometheus \
    --config.file=/export/server/prometheus/prometheus.yml \
    --storage.tsdb.path=/export/data/prometheus \
    --web.listen-address=CLUSTER_NODE1_IP:9090 \
    > /tmp/prometheus.out 2>&1 &
fi

if ! curl -fsS --max-time 4 http://CLUSTER_NODE1_IP:3000/login >/tmp/p15v2_grafana_precheck.out 2>/tmp/p15v2_grafana_precheck.err; then
  pgrep -f '/export/server/grafana/bin/grafana' | xargs -r kill 2>/dev/null || true
  pgrep -f 'grafana-server' | xargs -r kill 2>/dev/null || true
  sleep 2
  nohup env \
    GF_SERVER_HTTP_ADDR=CLUSTER_NODE1_IP \
    GF_SERVER_HTTP_PORT=3000 \
    GF_METRICS_ENABLED=true \
    /export/server/grafana/bin/grafana server \
    --homepath /export/server/grafana \
    > /tmp/grafana.out 2>&1 &
fi

sleep 8
ss -lntp | grep -E ':9090|:3000' || true
curl -sS -o /tmp/p15v2_prometheus_ready.out -w 'prometheus_ready_code=%{http_code}\n' --max-time 5 http://CLUSTER_NODE1_IP:9090/-/ready || true
curl -sS -o /tmp/p15v2_grafana_login.out -w 'grafana_login_code=%{http_code}\n' --max-time 5 http://CLUSTER_NODE1_IP:3000/login || true

