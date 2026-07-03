set -euo pipefail

LOG_DIR="/export/logs/atlas"
BUILD_LOG="${LOG_DIR}/atlas_build_berkeley_solr.log"

echo "[atlas-build-activity] process"
ps -eo pid,ppid,etime,pcpu,pmem,comm,args --no-headers \
  | awk '/[m]vn|[o]rg.codehaus.plexus.classworlds.launcher.Launcher|build_atlas_berkeley_solr/ && !/awk/ && !/v2_probe_atlas_build_activity/ {print}' \
  || true

echo "[atlas-build-activity] log-stat"
if [ -f "${BUILD_LOG}" ]; then
  stat -c 'size=%s mtime=%y' "${BUILD_LOG}"
else
  echo "__NO_BUILD_LOG__"
fi

echo "[atlas-build-activity] solr-download"
SOLR_TGZ="/export/build/apache-atlas-2.5.0/distro/solr/solr-8.11.3.tgz"
if [ -f "${SOLR_TGZ}" ]; then
  stat -c 'size=%s mtime=%y path=%n' "${SOLR_TGZ}"
  du -h "${SOLR_TGZ}" | awk '{print "human_size=" $1 " path=" $2}'
else
  echo "__NO_SOLR_TGZ__"
fi

echo "[atlas-build-activity] recent-raw-lines"
if [ -f "${BUILD_LOG}" ]; then
  tail -c 120000 "${BUILD_LOG}" \
    | tr '\r' '\n' \
    | grep -v '^Progress' \
    | sed '/^[[:space:]]*$/d' \
    | tail -n 80 \
    || true
fi
