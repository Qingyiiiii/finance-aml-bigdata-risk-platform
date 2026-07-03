set -euo pipefail

PLUGIN_JAR="/export/maven_repo/com/webcohesion/enunciate/enunciate-maven-plugin/2.13.2/enunciate-maven-plugin-2.13.2.jar"
SECURITY_ADMIN_POM="/export/build/apache-ranger-2.6.0/security-admin/pom.xml"
ROOT_POM="/export/build/apache-ranger-2.6.0/pom.xml"

echo "[security-admin-enunciate-plugin-context]"
sed -n '908,928p' "${SECURITY_ADMIN_POM}"

echo "[root-plugin-management-context]"
sed -n '464,478p' "${ROOT_POM}"

echo "[enunciate-plugin-skip-parameters]"
if [ -s "${PLUGIN_JAR}" ]; then
  unzip -p "${PLUGIN_JAR}" META-INF/maven/plugin.xml \
    | awk '
      /<goal>docs<\/goal>/ {in_docs=1}
      in_docs && /<\/mojo>/ {print; exit}
      in_docs {print}
    ' \
    | grep -i -C 4 'skip\|property'
else
  echo "plugin jar missing: ${PLUGIN_JAR}"
fi
