set -euo pipefail

NODE_IP="CLUSTER_NODE1_IP"
ADMIN_URL="http://${NODE_IP}:6080"

echo "[ranger-check] admin-service"
systemctl is-active finance-ranger-admin
systemctl is-enabled finance-ranger-admin

echo "[ranger-check] admin-http"
curl -fsS --max-time 5 "${ADMIN_URL}/login.jsp" >/dev/null
echo "login.jsp=OK"

echo "[ranger-check] listeners"
SS_6080="$(ss -lntp | awk '$4 ~ /:6080$/ {print}')"
printf '%s\n' "${SS_6080}"
if printf '%s\n' "${SS_6080}" | grep -Eq '0\.0\.0\.0:6080|\[::\]:6080|\*:6080'; then
  echo "unsafe_6080_bind=true"
  exit 4
fi
if ! printf '%s\n' "${SS_6080}" | grep -Eq "(${NODE_IP}:6080|\\[::ffff:${NODE_IP//./\\.}\\]:6080)"; then
  echo "expected_6080_bind_missing=true"
  exit 5
fi
echo "unsafe_6080_bind=false"

SS_5151="$(ss -lntp | awk '$4 ~ /:5151$/ {print}' || true)"
if [ -n "${SS_5151}" ]; then
  printf '%s\n' "${SS_5151}"
  if printf '%s\n' "${SS_5151}" | grep -Eq '0\.0\.0\.0:5151|\[::\]:5151|\*:5151'; then
    echo "unsafe_5151_bind=true"
    exit 6
  fi
else
  echo "listener_5151=none"
fi

echo "[ranger-check] database"
sudo -u postgres psql -d ranger_admin -Atc "select count(*) from information_schema.tables where table_schema='public';"
sudo -u postgres psql -Atc "select datname from pg_database where datname in ('ranger_admin','ranger_audit') order by datname;"

echo "[ranger-check] usersync"
if systemctl list-unit-files finance-ranger-usersync.service >/dev/null 2>&1; then
  systemctl is-active finance-ranger-usersync || true
  systemctl is-enabled finance-ranger-usersync || true
else
  echo "finance-ranger-usersync.service=missing"
fi
test -d /export/server/ranger-usersync
echo "usersync_home=present"

echo "[ranger-check] paths"
test -d /export/server/ranger-admin
test -d /export/logs/ranger/admin
test -f /etc/systemd/system/finance-ranger-admin.service
echo "ranger_admin_home=present"
echo "ranger_admin_url=${ADMIN_URL}"
echo "[ranger-check] done"

