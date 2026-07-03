set -euo pipefail

echo "[package-size]"
ls -lh /export/packages/ranger/ranger-2.6.0-admin.tar.gz /export/build/apache-ranger-2.6.0/target/ranger-2.6.0-admin.tar.gz

echo "[installed-webapp-tree]"
sudo find /export/server/ranger-admin/ews/webapp -maxdepth 4 -type d -printf '%p\n' | sort | sed -n '1,120p' || true

echo "[installed-key-files]"
sudo find /export/server/ranger-admin -maxdepth 6 -type f \( -name 'ranger-admin-site.xml' -o -name 'ranger-util-*.jar' -o -name 'logback.xml' -o -name '*.war' \) -printf '%p %s\n' | sort | sed -n '1,160p' || true

echo "[source-target-webapp]"
find /export/build/apache-ranger-2.6.0/security-admin/target -maxdepth 3 -type d -name 'WEB-INF' -o -type f -name 'security-admin-web-2.6.0.war' -o -type f -name 'ranger-admin-site.xml' | sort | sed -n '1,160p'

echo "[source-target-key-files]"
find /export/build/apache-ranger-2.6.0/security-admin/target -maxdepth 8 -type f \( -name 'ranger-admin-site.xml' -o -name 'ranger-util-*.jar' -o -name 'logback.xml' -o -name '*.war' \) -printf '%p %s\n' | sort | sed -n '1,220p'

echo "[tar-key-files]"
tar -tzf /export/packages/ranger/ranger-2.6.0-admin.tar.gz \
  | grep -E 'conf.dist|WEB-INF/lib|ranger-admin-site.xml|security-admin-web|ranger-util|logback.xml' \
  | sed -n '1,220p' || true
