set -euo pipefail

ATLAS_VERSION="2.5.0"
SRC_DIR="/export/build/apache-atlas-${ATLAS_VERSION}"
LOG_DIR="/export/logs/atlas"
M2_REPO="/export/maven_repo"
BUILD_LOG="${LOG_DIR}/atlas_build_berkeley_solr.log"
RC_FILE="${LOG_DIR}/atlas_build_berkeley_solr.rc"
RUNNER="${SRC_DIR}/build_atlas_berkeley_solr.sh"

echo "[atlas-build-start] host=$(hostname) user=$(whoami)"

if [ ! -d "${SRC_DIR}" ]; then
  echo "[atlas-build-start] missing source dir ${SRC_DIR}" >&2
  exit 2
fi

mkdir -p "${LOG_DIR}" "${M2_REPO}"
rm -f "${RC_FILE}"

cat > "${RUNNER}" <<'SH'
#!/usr/bin/env bash
set -u

ATLAS_VERSION="2.5.0"
SRC_DIR="/export/build/apache-atlas-${ATLAS_VERSION}"
LOG_DIR="/export/logs/atlas"
M2_REPO="/export/maven_repo"
BUILD_LOG="${LOG_DIR}/atlas_build_berkeley_solr.log"
RC_FILE="${LOG_DIR}/atlas_build_berkeley_solr.rc"

{
  echo "[atlas-build] start=$(date -Is)"
  echo "[atlas-build] host=$(hostname) user=$(whoami)"
  export JAVA_HOME="/export/server/jdk8"
  export PATH="${JAVA_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  export MAVEN_OPTS="-Xms1g -Xmx3g -XX:MaxMetaspaceSize=1g"
  cd "${SRC_DIR}"
  java -version 2>&1 | sed -n '1,3p'
  mvn -version | sed -n '1,4p'
  mvn \
    -Pdist,berkeley-solr,skipMinify \
    -DskipTests \
    -Dmaven.test.skip=true \
    -Dmaven.javadoc.skip=true \
    -Drat.skip=true \
    -Dcheckstyle.skip=true \
    -Dfindbugs.skip=true \
    -DskipITs=true \
    -Dmaven.repo.local="${M2_REPO}" \
    clean package
  RC=$?
  echo "[atlas-build] rc=${RC} end=$(date -Is)"
  find "${SRC_DIR}/distro/target" -maxdepth 2 -type f \( -name "*.tar.gz" -o -name "*.zip" \) -printf '%p %s\n' 2>/dev/null | sort
  echo "${RC}" > "${RC_FILE}"
  exit "${RC}"
} > "${BUILD_LOG}" 2>&1
SH

chmod +x "${RUNNER}"
nohup "${RUNNER}" >/dev/null 2>&1 &
PID=$!

echo "pid=${PID}"
echo "log=${BUILD_LOG}"
echo "rc_file=${RC_FILE}"
