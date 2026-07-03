set -euo pipefail

RANGER_VERSION=2.6.0
SRC_DIR="/export/build/apache-ranger-${RANGER_VERSION}"
PKG_DIR="/export/packages/ranger"
M2_REPO="/export/maven_repo"
LOG_DIR="/export/logs/ranger"
RESUME_LOG="${LOG_DIR}/ranger_resume_security_admin_web.log"
LAUNCH_LOG="${LOG_DIR}/ranger_resume_launcher.log"
RC_FILE="${LOG_DIR}/ranger_resume_security_admin_web.rc"
REMOTE_RUNNER="${SRC_DIR}/resume_security_admin_web_enunciate_skip.sh"

echo "[ranger-resume-start] host=$(hostname) user=$(whoami)"

if pgrep -f '[o]rg.codehaus.plexus.classworlds.launcher.Launcher.*apache-ranger-2.6.0' >/dev/null 2>&1; then
  echo "[ranger-resume-start] existing Maven process found; refusing to start another one"
  pgrep -af '[o]rg.codehaus.plexus.classworlds.launcher.Launcher.*apache-ranger-2.6.0'
  exit 2
fi

mkdir -p "${LOG_DIR}" "${PKG_DIR}"
rm -f "${RC_FILE}"

cat > "${REMOTE_RUNNER}" <<'EOF'
set -euo pipefail

RANGER_VERSION=2.6.0
SRC_DIR="/export/build/apache-ranger-${RANGER_VERSION}"
PKG_DIR="/export/packages/ranger"
M2_REPO="/export/maven_repo"
LOG_DIR="/export/logs/ranger"
RESUME_LOG="${LOG_DIR}/ranger_resume_security_admin_web.log"
RC_FILE="${LOG_DIR}/ranger_resume_security_admin_web.rc"

JAVA11_HOME="$(dirname "$(dirname "$(readlink -f /usr/lib/jvm/java-11-openjdk*/bin/javac | head -n 1)")")"
export JAVA_HOME="${JAVA11_HOME}"
export PATH="${JAVA_HOME}/bin:${PATH}"
export MAVEN_OPTS="-Xms1g -Xmx3g -XX:MaxMetaspaceSize=1g"

cd "${SRC_DIR}"

{
  echo "[ranger-resume] start=$(date -Is)"
  echo "[ranger-resume] java_home=${JAVA_HOME}"
  java -version 2>&1 | sed -n '1,3p'
  mvn -version | sed -n '1,4p'
  echo "[ranger-resume] command=mvn -Pall ... -Denunciate.skip=true -rf :security-admin-web package"
} >"${RESUME_LOG}" 2>&1

set +e
mvn \
  -Pall \
  -DskipTests \
  -Dmaven.test.skip=true \
  -Dmaven.javadoc.skip=true \
  -Drat.skip=true \
  -Dcheckstyle.skip=true \
  -Dspotbugs.skip=true \
  -Denunciate.skip=true \
  -Dmaven.repo.local="${M2_REPO}" \
  -rf :security-admin-web \
  package \
  >>"${RESUME_LOG}" 2>&1
BUILD_RC=$?
set -e

echo "${BUILD_RC}" > "${RC_FILE}"
echo "[ranger-resume] rc=${BUILD_RC} end=$(date -Is)" >>"${RESUME_LOG}"

if [ "${BUILD_RC}" -eq 0 ]; then
  find target -maxdepth 1 -type f -name "ranger-${RANGER_VERSION}-*.tar.gz" -printf '%f\n' | sort >>"${RESUME_LOG}" || true
  if [ -f "target/ranger-${RANGER_VERSION}-admin.tar.gz" ]; then
    cp "target/ranger-${RANGER_VERSION}-admin.tar.gz" "${PKG_DIR}/"
  fi
  if [ -f "target/ranger-${RANGER_VERSION}-usersync.tar.gz" ]; then
    cp "target/ranger-${RANGER_VERSION}-usersync.tar.gz" "${PKG_DIR}/"
  fi
fi

exit "${BUILD_RC}"
EOF

chmod 700 "${REMOTE_RUNNER}"

nohup bash "${REMOTE_RUNNER}" >"${LAUNCH_LOG}" 2>&1 &
BUILD_PID=$!
echo "[ranger-resume-start] pid=${BUILD_PID}"
echo "[ranger-resume-start] log=${RESUME_LOG}"
echo "[ranger-resume-start] rc_file=${RC_FILE}"
