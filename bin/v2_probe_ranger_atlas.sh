set -euo pipefail

source /etc/profile.d/bigdata.sh 2>/dev/null || true
export JAVA_HOME=/export/server/jdk17
export PATH=/export/server/hadoop/bin:/export/server/hadoop/sbin:/export/server/spark/bin:$JAVA_HOME/bin:$PATH

echo "[host]"
hostname
whoami

echo "[java]"
java -version 2>&1 | sed -n '1,4p'

echo "[build tools]"
for c in mvn git gcc make tar curl python3.11 python3; do
  if command -v "$c" >/dev/null 2>&1; then
    printf '%s=' "$c"
    "$c" --version 2>&1 | head -n 1
  else
    echo "$c=missing"
  fi
done

echo "[postgres]"
if command -v psql >/dev/null 2>&1; then
  psql --version
else
  echo "psql=missing"
fi
systemctl is-active postgresql >/dev/null 2>&1 && echo "postgresql=active" || echo "postgresql=not-active"
ss -lntp | grep -E ':5432\b' || true

echo "[governance ports]"
ss -lntp | grep -E ':6080\b|:21000\b' || true

echo "[existing paths]"
for p in /export/server/ranger-admin /export/server/ranger-usersync /export/server/atlas /export/data/ranger /export/data/atlas; do
  if [ -e "$p" ]; then
    ls -ld "$p"
  else
    echo "$p=missing"
  fi
done

echo "[apache download candidates]"
for url in \
  https://downloads.apache.org/ranger/ \
  https://downloads.apache.org/atlas/ \
  https://archive.apache.org/dist/ranger/ \
  https://archive.apache.org/dist/atlas/; do
  echo "URL=$url"
  curl -fsSL "$url" | sed -n '1,20p' | grep -E 'href|Index of' || true
done
