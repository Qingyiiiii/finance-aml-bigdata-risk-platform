#!/usr/bin/env bash
# Verify Prometheus/Grafana after P15v2 monitoring repair.
set -uo pipefail

REMOTE_ROOT=${REMOTE_ROOT:-/home/common/tmp/finance_bigdata_project}
REPAIR_NAME=${REPAIR_NAME:-p15v2_service_repair_20260703_015213}
RUN_DIR="$REMOTE_ROOT/runs/$REPAIR_NAME"
mkdir -p "$RUN_DIR"

status="$RUN_DIR/prometheus_grafana_repair.tsv"
echo -e "check\tstatus\tdetail" > "$status"

record() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$status"
}

if curl -fsS --max-time 8 http://CLUSTER_NODE1_IP:9090/-/ready > "$RUN_DIR/prometheus_ready_after_repair.out" 2> "$RUN_DIR/prometheus_ready_after_repair.err"; then
  record prometheus_ready PASS http_200
else
  record prometheus_ready FAIL "$RUN_DIR/prometheus_ready_after_repair.err"
fi

if curl -fsS --max-time 8 http://CLUSTER_NODE1_IP:3000/login > "$RUN_DIR/grafana_login_after_repair.html" 2> "$RUN_DIR/grafana_login_after_repair.err"; then
  record grafana_login PASS http_200
else
  record grafana_login FAIL "$RUN_DIR/grafana_login_after_repair.err"
fi

if curl -fsS --max-time 8 http://CLUSTER_NODE1_IP:9090/api/v1/targets > "$RUN_DIR/prometheus_targets_after_repair.json" 2> "$RUN_DIR/prometheus_targets_after_repair.err"; then
  up_count=$(python3 - "$RUN_DIR/prometheus_targets_after_repair.json" <<'PY' 2>/dev/null || echo 0
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
targets = data.get("data", {}).get("activeTargets", [])
print(sum(1 for target in targets if target.get("health") == "up"))
PY
)
  record prometheus_targets_up PASS "${up_count:-0}"
else
  record prometheus_targets_up FAIL "$RUN_DIR/prometheus_targets_after_repair.err"
fi

if [ -f /export/server/grafana/data/dashboards/finance_bigdata_v2/finance_bigdata_v2_overview.json ]; then
  record grafana_dashboard_json PASS /export/server/grafana/data/dashboards/finance_bigdata_v2/finance_bigdata_v2_overview.json
else
  record grafana_dashboard_json FAIL missing
fi

ss -lntp | grep -E ':9090|:3000' > "$RUN_DIR/prometheus_grafana_ports_after_repair.out" 2>&1 || true
cat "$status"

