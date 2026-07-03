set -euo pipefail

ATLAS_VERSION="2.5.0"
ATLAS_TGZ="apache-atlas-${ATLAS_VERSION}-sources.tar.gz"
ATLAS_URL="https://downloads.apache.org/atlas/${ATLAS_VERSION}/${ATLAS_TGZ}"
ATLAS_SHA_URL="${ATLAS_URL}.sha512"
BUILD_ROOT="/export/build"
SRC_DIR="${BUILD_ROOT}/apache-atlas-${ATLAS_VERSION}"
PKG_DIR="/export/packages/atlas"
LOG_DIR="/export/logs/atlas"

echo "[atlas-prepare] host=$(hostname) user=$(whoami)"
sudo mkdir -p "${BUILD_ROOT}" "${PKG_DIR}" "${LOG_DIR}" /export/maven_repo
sudo chown -R common:common "${BUILD_ROOT}" "${PKG_DIR}" "${LOG_DIR}" /export/maven_repo

if [ ! -s "${PKG_DIR}/${ATLAS_TGZ}" ]; then
  echo "[download] ${ATLAS_URL}"
  curl -fL --retry 3 --retry-delay 5 "${ATLAS_URL}" -o "${PKG_DIR}/${ATLAS_TGZ}"
else
  echo "[download] exists ${PKG_DIR}/${ATLAS_TGZ}"
fi

if [ ! -s "${PKG_DIR}/${ATLAS_TGZ}.sha512" ]; then
  echo "[download] ${ATLAS_SHA_URL}"
  curl -fL --retry 3 --retry-delay 5 "${ATLAS_SHA_URL}" -o "${PKG_DIR}/${ATLAS_TGZ}.sha512"
else
  echo "[download] exists ${PKG_DIR}/${ATLAS_TGZ}.sha512"
fi

echo "[download] sha512 validation"
EXPECTED_SHA="$(
  grep -Eo '[A-Fa-f0-9]+' "${PKG_DIR}/${ATLAS_TGZ}.sha512" \
    | awk 'length($0) >= 8 {printf "%s", tolower($0)} END {print ""}'
)"
ACTUAL_SHA="$(sha512sum "${PKG_DIR}/${ATLAS_TGZ}" | awk '{print $1}')"
if [ "${EXPECTED_SHA}" != "${ACTUAL_SHA}" ]; then
  echo "[atlas-prepare] sha512 mismatch" >&2
  exit 2
fi
echo "sha512=OK"

echo "[extract]"
if [ ! -d "${SRC_DIR}" ]; then
  tar -xzf "${PKG_DIR}/${ATLAS_TGZ}" -C "${BUILD_ROOT}"
fi

echo "[source]"
ls -ld "${SRC_DIR}"
find "${SRC_DIR}" -maxdepth 2 -type f \( -name pom.xml -o -name README.md -o -name BUILDING.txt \) -printf '%p\n' | sort

echo "[maven-profiles]"
grep -RIn "<id>.*</id>" "${SRC_DIR}/pom.xml" "${SRC_DIR}"/distro/pom.xml 2>/dev/null | sed -n '1,160p' || true

echo "[tool-versions]"
JAVA11_HOME="$(dirname "$(dirname "$(readlink -f /usr/lib/jvm/java-11-openjdk*/bin/javac | head -n 1)")")"
export JAVA_HOME="${JAVA11_HOME}"
export PATH="${JAVA_HOME}/bin:${PATH}"
java -version 2>&1 | sed -n '1,3p'
mvn -version | sed -n '1,4p'
if command -v node >/dev/null 2>&1; then node --version; else echo "node=missing"; fi
if command -v npm >/dev/null 2>&1; then npm --version; else echo "npm=missing"; fi

echo "[atlas-prepare] done"
