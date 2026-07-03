set -euo pipefail

ATLAS_VERSION="2.5.0"
SRC_DIR="/export/build/apache-atlas-${ATLAS_VERSION}"
LOG_DIR="/export/logs/atlas"
BUILD_LOG="${LOG_DIR}/atlas_build_berkeley_solr.log"
RC_FILE="${LOG_DIR}/atlas_build_berkeley_solr.rc"
RUNNER="${SRC_DIR}/resume_atlas_distro.sh"
SOLR_DIR="${SRC_DIR}/distro/solr"
SOLR_TGZ="${SOLR_DIR}/solr-8.11.3.tgz"
SOLR_URL="https://archive.apache.org/dist/lucene/solr/8.11.3/solr-8.11.3.tgz"

echo "[atlas-retry] ensure no active atlas maven build"
if ps -eo args --no-headers | grep -E '[o]rg.codehaus.plexus.classworlds.launcher.Launcher .*-Pdist,berkeley-solr' >/dev/null; then
  echo "__ATLAS_MAVEN_STILL_RUNNING__"
  exit 1
fi

mkdir -p "${LOG_DIR}" "${SOLR_DIR}"

echo "[atlas-retry] remove corrupt solr tgz"
rm -f "${SOLR_TGZ}" "${SOLR_TGZ}.download"

echo "[atlas-retry] download solr with retries"
for attempt in 1 2 3; do
  echo "[atlas-retry] solr download attempt=${attempt}"
  rm -f "${SOLR_TGZ}.download"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 5 --retry-delay 10 --connect-timeout 30 --max-time 1800 \
      -o "${SOLR_TGZ}.download" "${SOLR_URL}"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=5 --timeout=30 -O "${SOLR_TGZ}.download" "${SOLR_URL}"
  else
    echo "__NO_CURL_OR_WGET__"
    exit 1
  fi

  mv "${SOLR_TGZ}.download" "${SOLR_TGZ}"
  stat -c '[atlas-retry] solr size=%s mtime=%y' "${SOLR_TGZ}"
  if gzip -t "${SOLR_TGZ}" && tar -tzf "${SOLR_TGZ}" >/dev/null; then
    echo "[atlas-retry] solr archive validation PASS"
    break
  fi

  echo "[atlas-retry] solr archive validation FAILED"
  rm -f "${SOLR_TGZ}"
  if [ "${attempt}" = "3" ]; then
    exit 1
  fi
  sleep 10
done

cat > "${RUNNER}" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail

export JAVA_HOME="/export/server/jdk8"
export PATH="${JAVA_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export MAVEN_OPTS="-Xms1g -Xmx3g -XX:MaxMetaspaceSize=1g"

SRC_DIR="/export/build/apache-atlas-2.5.0"
LOG_DIR="/export/logs/atlas"
BUILD_LOG="${LOG_DIR}/atlas_build_berkeley_solr.log"
RC_FILE="${LOG_DIR}/atlas_build_berkeley_solr.rc"

cd "${SRC_DIR}"
{
  echo "[atlas-resume] start $(date -Is)"
  set +e
  mvn -Pdist,berkeley-solr,skipMinify \
    -DskipTests \
    -Dmaven.test.skip=true \
    -Dmaven.javadoc.skip=true \
    -Drat.skip=true \
    -Dcheckstyle.skip=true \
    -Dfindbugs.skip=true \
    -DskipITs=true \
    -Dmaven.repo.local=/export/maven_repo \
    -rf :atlas-distro \
    package
  rc=$?
  set -e
  echo "${rc}" > "${RC_FILE}"
  echo "[atlas-resume] end $(date -Is) rc=${rc}"
  exit "${rc}"
} >> "${BUILD_LOG}" 2>&1
RUNNER
chmod +x "${RUNNER}"

rm -f "${RC_FILE}"
echo "[atlas-retry] start resume runner"
nohup bash "${RUNNER}" > "${LOG_DIR}/atlas_build_berkeley_solr.resume.out" 2>&1 &
echo "[atlas-retry] pid=$!"
