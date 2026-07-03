set -euo pipefail

RANGER_VERSION=2.6.0
SRC_DIR="/export/build/apache-ranger-${RANGER_VERSION}"
PKG_DIR="/export/packages/ranger"
LOG_DIR="/export/logs/ranger"
RESUME_LOG="${LOG_DIR}/ranger_resume_security_admin_web.log"
RC_FILE="${LOG_DIR}/ranger_resume_security_admin_web.rc"

echo "[ranger-resume-check] processes"
ps -eo pid,ppid,etime,comm,args --no-headers \
  | awk '/[m]vn|[o]rg.codehaus.plexus.classworlds.launcher.Launcher/ && !/awk/ && !/v2_check_ranger_resume_build/ {print}' \
  || true

echo "[ranger-resume-check] rc"
if [ -f "${RC_FILE}" ]; then
  cat "${RC_FILE}"
else
  echo "__RUNNING_OR_NOT_WRITTEN__"
fi

echo "[ranger-resume-check] log-tail"
tail -n 120 "${RESUME_LOG}" 2>/dev/null || true

echo "[ranger-resume-check] target-archives"
find "${SRC_DIR}/target" -maxdepth 1 -type f -name "ranger-${RANGER_VERSION}-*.tar.gz" -printf '%f %s\n' 2>/dev/null | sort || true

echo "[ranger-resume-check] package-archives"
find "${PKG_DIR}" -maxdepth 1 -type f -name "ranger-${RANGER_VERSION}-*.tar.gz" -printf '%f %s\n' 2>/dev/null | sort || true
