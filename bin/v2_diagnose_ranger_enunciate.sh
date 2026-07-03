set -euo pipefail

SRC_DIR="/export/build/apache-ranger-2.6.0"
BUILD_LOG="/export/logs/ranger/ranger_build.log"

echo "[process-check]"
pgrep -af '[o]rg.codehaus.plexus.classworlds.launcher.Launcher.*apache-ranger-2.6.0' || true

echo "[build-log-error-tail]"
tail -n 220 "${BUILD_LOG}" 2>/dev/null || true

echo "[module-poms]"
find "${SRC_DIR}" -maxdepth 3 -name pom.xml -print | sort | grep -E 'security-admin|pom.xml$' | sed -n '1,120p'

echo "[artifact-security-admin-web]"
grep -RIn '<artifactId>security-admin-web</artifactId>\|<artifactId>.*admin.*web.*</artifactId>' "${SRC_DIR}" --include=pom.xml | sed -n '1,80p' || true

echo "[enunciate-references]"
grep -RIn 'enunciate\|webcohesion' "${SRC_DIR}" --include=pom.xml --include='*.xml' --include='*.properties' | sed -n '1,220p' || true

echo "[skip-properties-near-enunciate]"
grep -RIn 'skip.*enunciate\|enunciate.*skip\|skipDocs\|skip.docs\|docs.skip\|maven.javadoc.skip' "${SRC_DIR}" --include=pom.xml --include='*.xml' --include='*.properties' | sed -n '1,220p' || true

echo "[security-admin-pom-enunciate-context]"
SECURITY_ADMIN_POM="${SRC_DIR}/security-admin/pom.xml"
if [ -f "${SECURITY_ADMIN_POM}" ]; then
  grep -n 'enunciate\|webcohesion\|skip' "${SECURITY_ADMIN_POM}" || true
  echo "[security-admin-pom-lines-1800-1920]"
  sed -n '1800,1920p' "${SECURITY_ADMIN_POM}" || true
  echo "[security-admin-pom-lines-1920-2040]"
  sed -n '1920,2040p' "${SECURITY_ADMIN_POM}" || true
fi

echo "[root-pom-relevant-properties]"
ROOT_POM="${SRC_DIR}/pom.xml"
if [ -f "${ROOT_POM}" ]; then
  grep -n 'enunciate\|skip\|profile\|security-admin-web' "${ROOT_POM}" | sed -n '1,220p' || true
fi

echo "[target-archives]"
find "${SRC_DIR}/target" -maxdepth 1 -type f -name '*.tar.gz' -printf '%f %s\n' 2>/dev/null | sort || true
