set -euo pipefail

echo "[admin-jar-dirs]"
sudo find /export/server/ranger-admin -maxdepth 4 -type d \( -name lib -o -name jisql -o -name cred \) -printf '%p\n' | sort

echo "[admin-existing-jars]"
sudo find /export/server/ranger-admin -maxdepth 7 -type f \( -name '*jisql*.jar' -o -name '*credential*.jar' -o -name 'ranger-util-*.jar' -o -name 'ranger-credential*.jar' \) -printf '%p %s\n' | sort | sed -n '1,200p'

echo "[build-jars]"
find /export/build/apache-ranger-2.6.0 /export/maven_repo -type f \( -name '*jisql*.jar' -o -name '*credential*.jar' -o -name 'ranger-util-*.jar' -o -name 'ranger-credential*.jar' \) -printf '%p %s\n' | sort | sed -n '1,260p'

echo "[package-jisql-cred]"
tar -tzf /export/packages/ranger/ranger-2.6.0-admin.tar.gz | grep -E 'jisql|cred|credential|ranger-util' | sed -n '1,220p' || true
