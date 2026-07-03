set -euo pipefail

echo "[maven processes]"
ps -eo pid,ppid,etime,comm,args --no-headers \
  | awk '/[m]vn|[o]rg.codehaus.plexus.classworlds.launcher.Launcher/ && !/awk/ && !/v2_check_ranger_build/ {print}' \
  || true

echo "[build log tail]"
tail -n 160 /export/logs/ranger/ranger_build.log 2>/dev/null || true

echo "[target archives]"
find /export/build/apache-ranger-2.6.0/target -maxdepth 1 -type f -name '*.tar.gz' -printf '%f %s\n' 2>/dev/null | sort || true

echo "[disk]"
df -h /export /tmp
