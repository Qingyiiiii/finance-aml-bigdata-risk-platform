set -euo pipefail

echo "[usersync-package-size]"
ls -lh /export/packages/ranger/ranger-2.6.0-usersync.tar.gz /export/build/apache-ranger-2.6.0/target/ranger-2.6.0-usersync.tar.gz

echo "[installed-usersync-tree]"
sudo find /export/server/ranger-usersync -maxdepth 3 -type d -printf '%p\n' | sort | sed -n '1,160p'

echo "[installed-usersync-key-files]"
sudo find /export/server/ranger-usersync -maxdepth 6 -type f \( -name '*.jar' -o -name 'unixauthservice.properties' -o -name 'ranger-ugsync-site.xml' \) -printf '%p %s\n' | sort | sed -n '1,220p'

echo "[build-usersync-key-files]"
find /export/build/apache-ranger-2.6.0 -path '*target*' -type f \( -name '*usersync*.jar' -o -name '*unixauth*.jar' -o -name 'unixauthservice.properties' -o -name 'ranger-ugsync-site.xml' \) -printf '%p %s\n' | sort | sed -n '1,260p'

echo "[tar-usersync-key-files]"
tar -tzf /export/packages/ranger/ranger-2.6.0-usersync.tar.gz | grep -E 'jar$|unixauthservice|ranger-ugsync|conf.dist|lib/' | sed -n '1,220p' || true
