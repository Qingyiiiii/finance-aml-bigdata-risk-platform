set -euo pipefail

echo "[host]"
hostname
whoami

echo "[ports]"
ss -lntp | awk '$4 ~ /:21000$/ || $4 ~ /:2181$/ || $4 ~ /:16000$/ || $4 ~ /:16010$/ {print}' || true

echo "[services]"
for svc in zookeeper hbase-master hbase-regionserver atlas finance-atlas; do
  if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
    printf '%s=' "${svc}"
    systemctl is-active "${svc}" || true
  fi
done

echo "[processes]"
jps -l 2>/dev/null | awk '/HMaster|HRegionServer|QuorumPeerMain|Atlas|Solr|Kafka|Elastic/ {print}' || true

echo "[paths]"
for p in /export/server/atlas /export/data/atlas /export/logs/atlas /export/packages/atlas /export/build/apache-atlas-2.5.0; do
  if [ -e "$p" ]; then
    ls -ld "$p"
  else
    echo "$p=missing"
  fi
done

echo "[packages]"
find /export/packages /export/build -maxdepth 4 -type f \( -name '*atlas*2.5.0*.tar.gz' -o -name '*atlas*2.5.0*.zip' \) -printf '%p %s\n' 2>/dev/null | sort || true

echo "[java]"
for j in /export/server/jdk8/bin/java /usr/lib/jvm/java-11-openjdk/bin/java /export/server/jdk17/bin/java; do
  if [ -x "$j" ]; then
    echo "JAVA=$j"
    "$j" -version 2>&1 | sed -n '1,3p'
  fi
done

echo "[hbase-shell]"
if [ -x /export/server/hbase/bin/hbase ]; then
  /export/server/hbase/bin/hbase version 2>/dev/null | sed -n '1,3p' || true
fi
