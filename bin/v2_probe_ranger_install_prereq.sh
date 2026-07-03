set -euo pipefail

echo "[host]"
hostname
whoami

echo "[postgres-service]"
if systemctl is-active --quiet postgresql; then
  echo "postgresql=active"
elif systemctl is-active --quiet postgresql-15; then
  echo "postgresql-15=active"
else
  echo "postgresql=not-active"
fi
ss -lntp | awk '$4 ~ /:5432$/ {print}'

echo "[postgres-databases]"
sudo -S -p '' -u postgres psql -Atc "select datname from pg_database where datname in ('metastore_hive313','dolphinscheduler','ranger_admin','ranger_audit') order by datname;"

echo "[postgres-roles]"
sudo -S -p '' -u postgres psql -Atc "select rolname from pg_roles where rolname in ('hive','rangeradmin','rangeraudit') order by rolname;"

echo "[ranger-packages]"
ls -lh /export/packages/ranger/ranger-2.6.0-admin.tar.gz /export/packages/ranger/ranger-2.6.0-usersync.tar.gz

echo "[ports]"
ss -lntp | awk '$4 ~ /:6080$/ || $4 ~ /:5151$/ {print}' || true

echo "[paths]"
for p in /export/server/ranger-admin /export/server/ranger-usersync /export/data/ranger /export/logs/ranger; do
  if [ -e "$p" ]; then
    ls -ld "$p"
  else
    echo "$p=missing"
  fi
done

echo "[java11]"
if [ -x /usr/lib/jvm/java-11-openjdk/bin/java ]; then
  /usr/lib/jvm/java-11-openjdk/bin/java -version 2>&1 | sed -n '1,3p'
else
  readlink -f /usr/lib/jvm/java-11-openjdk*/bin/java 2>/dev/null | head -n 1
fi
