set -euo pipefail

echo "[paths]"
for p in /export/server/ranger-admin /export/server/ranger-usersync /export/logs/ranger/admin /export/logs/ranger/usersync /export/run/ranger; do
  if [ -e "$p" ]; then
    ls -ld "$p"
  else
    echo "$p=missing"
  fi
done

echo "[admin-setup-log]"
if sudo test -f /export/logs/ranger/admin/setup.log; then
  sudo tail -n 180 /export/logs/ranger/admin/setup.log \
    | sed -E 's/(password|PASSWORD|PassWord)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\2***/g'
else
  echo "missing /export/logs/ranger/admin/setup.log"
fi

echo "[admin-local-logfile]"
if sudo test -f /export/server/ranger-admin/logfile; then
  sudo tail -n 180 /export/server/ranger-admin/logfile \
    | sed -E 's/(password|PASSWORD|PassWord)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\2***/g'
else
  echo "missing /export/server/ranger-admin/logfile"
fi

echo "[postgres-ranger-tables]"
sudo -u postgres psql -Atc "select datname from pg_database where datname in ('ranger_admin','ranger_audit') order by datname;"
sudo -u postgres psql -d ranger_admin -Atc "select count(*) from information_schema.tables where table_schema='public';" || true
