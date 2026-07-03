set -euo pipefail

ATLAS_VERSION="2.5.0"
SRC_DIR="/export/build/apache-atlas-${ATLAS_VERSION}"
LOG_DIR="/export/logs/atlas"
BUILD_LOG="${LOG_DIR}/atlas_build_berkeley_solr.log"
RC_FILE="${LOG_DIR}/atlas_build_berkeley_solr.rc"

echo "[atlas-build-check] processes"
ps -eo pid,ppid,etime,comm,args --no-headers \
  | awk '/[m]vn|[o]rg.codehaus.plexus.classworlds.launcher.Launcher|build_atlas_berkeley_solr/ && !/awk/ && !/v2_check_atlas_build/ {print}' \
  || true

echo "[atlas-build-check] rc"
if [ -f "${RC_FILE}" ]; then
  cat "${RC_FILE}"
else
  echo "__RUNNING_OR_NOT_WRITTEN__"
fi

echo "[atlas-build-check] log-key-lines"
if [ -f "${BUILD_LOG}" ]; then
  tail -c 500000 "${BUILD_LOG}" \
    | tr '\r' '\n' \
    | grep -E '^\[INFO\] (Building |Reactor Summary|BUILD |Total time|Finished at|Building jar:|--- )|^\[ERROR\]|^\[WARNING\]|Failed to|Caused by' \
    | tail -n 100 \
    || true
else
  echo "__NO_BUILD_LOG__"
fi

echo "[atlas-build-check] artifacts"
find "${SRC_DIR}/distro/target" -maxdepth 3 -type f \( -name "*.tar.gz" -o -name "*.zip" \) -printf '%p %s\n' 2>/dev/null | sort || true

echo "[atlas-build-check] disk"
df -h /export /tmp
