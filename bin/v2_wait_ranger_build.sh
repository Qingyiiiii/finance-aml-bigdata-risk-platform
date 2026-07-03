set -euo pipefail

BUILD_LOG="/export/logs/ranger/ranger_build.log"
TARGET_DIR="/export/build/apache-ranger-2.6.0/target"
MAX_MINUTES="${1:-90}"

for i in $(seq 1 "${MAX_MINUTES}"); do
  echo "[wait] minute=${i}/${MAX_MINUTES}"
  if ! pgrep -f '[o]rg.codehaus.plexus.classworlds.launcher.Launcher.*apache-ranger-2.6.0' >/dev/null 2>&1; then
    echo "[wait] maven process is no longer running"
    break
  fi
  echo "[wait] maven still running"
  echo "[wait] log tail"
  tail -n 25 "${BUILD_LOG}" 2>/dev/null || true
  echo "[wait] archive candidates"
  find "${TARGET_DIR}" -maxdepth 1 -type f -name '*.tar.gz' -printf '%f %s\n' 2>/dev/null | sort || true
  sleep 60
done

echo "[final processes]"
pgrep -af '[o]rg.codehaus.plexus.classworlds.launcher.Launcher.*apache-ranger-2.6.0' || true

echo "[final log tail]"
tail -n 120 "${BUILD_LOG}" 2>/dev/null || true

echo "[final archives]"
find "${TARGET_DIR}" -maxdepth 1 -type f -name '*.tar.gz' -printf '%f %s\n' 2>/dev/null | sort || true
