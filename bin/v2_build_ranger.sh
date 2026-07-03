set -euo pipefail

RANGER_VERSION=2.6.0
RANGER_TGZ="apache-ranger-${RANGER_VERSION}.tar.gz"
RANGER_URL="https://downloads.apache.org/ranger/${RANGER_VERSION}/${RANGER_TGZ}"
RANGER_SHA_URL="${RANGER_URL}.sha512"
BUILD_ROOT="/export/build"
SRC_DIR="${BUILD_ROOT}/apache-ranger-${RANGER_VERSION}"
PKG_DIR="/export/packages/ranger"
M2_REPO="/export/maven_repo"
LOG_DIR="/export/logs/ranger"
BUILD_LOG="${LOG_DIR}/ranger_build.log"

echo "[ranger-build] host=$(hostname) user=$(whoami)"
echo "[ranger-build] version=${RANGER_VERSION}"

sudo mkdir -p "${BUILD_ROOT}" "${PKG_DIR}" "${M2_REPO}" "${LOG_DIR}"
sudo chown -R common:common "${BUILD_ROOT}" "${PKG_DIR}" "${M2_REPO}" "${LOG_DIR}"

if [ ! -s "${PKG_DIR}/${RANGER_TGZ}" ]; then
  echo "[download] ${RANGER_URL}"
  curl -fL --retry 3 --retry-delay 5 "${RANGER_URL}" -o "${PKG_DIR}/${RANGER_TGZ}"
else
  echo "[download] exists ${PKG_DIR}/${RANGER_TGZ}"
fi

if [ ! -s "${PKG_DIR}/${RANGER_TGZ}.sha512" ]; then
  curl -fL --retry 3 --retry-delay 5 "${RANGER_SHA_URL}" -o "${PKG_DIR}/${RANGER_TGZ}.sha512"
fi

echo "[download] sha512 validation"
EXPECTED_SHA="$(grep -Eo '[A-Fa-f0-9]{128}' "${PKG_DIR}/${RANGER_TGZ}.sha512" | head -n 1)"
ACTUAL_SHA="$(sha512sum "${PKG_DIR}/${RANGER_TGZ}" | awk '{print $1}')"
if [ "${EXPECTED_SHA}" != "${ACTUAL_SHA}" ]; then
  echo "[ranger-build] sha512 mismatch" >&2
  exit 2
fi
echo "sha512=OK"

echo "[extract] source"
if [ ! -d "${SRC_DIR}" ]; then
  tar -xzf "${PKG_DIR}/${RANGER_TGZ}" -C "${BUILD_ROOT}"
fi

JAVA11_HOME="$(dirname "$(dirname "$(readlink -f /usr/lib/jvm/java-11-openjdk*/bin/javac | head -n 1)")")"
export JAVA_HOME="${JAVA11_HOME}"
export PATH="${JAVA_HOME}/bin:${PATH}"
export MAVEN_OPTS="-Xms1g -Xmx3g -XX:MaxMetaspaceSize=1g"

echo "[versions]"
java -version 2>&1 | sed -n '1,3p'
mvn -version | sed -n '1,4p'

cd "${SRC_DIR}"

if ls target/ranger-${RANGER_VERSION}-admin.tar.gz target/ranger-${RANGER_VERSION}-usersync.tar.gz >/dev/null 2>&1; then
  echo "[build] existing Ranger admin/usersync archives found"
else
  echo "[build] Maven build starts; log=${BUILD_LOG}"
  set +e
  mvn \
    -Pall \
    -DskipTests \
    -Dmaven.test.skip=true \
    -Dmaven.javadoc.skip=true \
    -Drat.skip=true \
    -Dcheckstyle.skip=true \
    -Dspotbugs.skip=true \
    -Dmaven.repo.local="${M2_REPO}" \
    clean package \
    >"${BUILD_LOG}" 2>&1
  BUILD_RC=$?
  set -e
  if [ "${BUILD_RC}" -ne 0 ]; then
    echo "[ranger-build] Maven build failed; tail follows" >&2
    tail -n 160 "${BUILD_LOG}" >&2 || true
    exit "${BUILD_RC}"
  fi
fi

echo "[build] target archives"
find target -maxdepth 1 -type f -name "ranger-${RANGER_VERSION}-*.tar.gz" -printf '%f\n' | sort

echo "[build] copy admin/usersync archives"
cp "target/ranger-${RANGER_VERSION}-admin.tar.gz" "${PKG_DIR}/"
cp "target/ranger-${RANGER_VERSION}-usersync.tar.gz" "${PKG_DIR}/"
ls -lh "${PKG_DIR}/ranger-${RANGER_VERSION}-admin.tar.gz" "${PKG_DIR}/ranger-${RANGER_VERSION}-usersync.tar.gz"

echo "[ranger-build] done"
