set -euo pipefail

echo "[candidate-ranger-jars]"
find /export/build/apache-ranger-2.6.0 /export/maven_repo/org/apache/ranger \
  -type f \( -name 'ranger-common*.jar' -o -name 'ranger-common-ha*.jar' -o -name 'ranger-plugins-common*.jar' -o -name 'ranger-intg*.jar' -o -name 'ranger-util*.jar' \) \
  -printf '%p\n' | sort | sed -n '1,200p'

echo "[RangerHAInitializer-candidates]"
find /export/build/apache-ranger-2.6.0 /export/maven_repo/org/apache/ranger \
  -type f \( -name 'ranger-common*.jar' -o -name 'ranger-common-ha*.jar' -o -name 'ranger-plugins-common*.jar' -o -name 'ranger-intg*.jar' -o -name 'ranger-util*.jar' \) \
  | while read -r jar_file; do
      if jar tf "${jar_file}" 2>/dev/null | grep -q 'org/apache/ranger/RangerHAInitializer.class'; then
        echo "${jar_file}"
      fi
    done

echo "[ugsync-conf-files]"
find /export/server/ranger-usersync /export/build/apache-ranger-2.6.0/ugsync \
  -type f \( -name 'ranger-ugsync-site.xml' -o -name 'ranger-ugsync-default.xml' -o -name '*ugsync*template*' \) \
  -printf '%p\n' | sort | sed -n '1,120p'
