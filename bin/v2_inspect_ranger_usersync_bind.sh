set -euo pipefail

SRC_DIR="/export/build/apache-ranger-2.6.0"

echo "[usersync-bind-grep]"
grep -RInE 'UnixAuthenticationService|authServicePort|5151|ServerSocket|setReuseAddress|bind|InetAddress|ranger.usersync|unixauth' \
  "${SRC_DIR}/ugsync" "${SRC_DIR}/unixauthservice" "${SRC_DIR}/security-admin/src/main" \
  | sed -n '1,260p' || true
