set -euo pipefail

ADMIN_DIR="/tmp/ranger_admin_inspect/ranger-2.6.0-admin"
USER_SYNC_DIR="/tmp/ranger_usersync_inspect/ranger-2.6.0-usersync"

if [ ! -d "${ADMIN_DIR}" ]; then
  rm -rf /tmp/ranger_admin_inspect
  mkdir -p /tmp/ranger_admin_inspect
  tar -xzf /export/packages/ranger/ranger-2.6.0-admin.tar.gz -C /tmp/ranger_admin_inspect
fi

if [ ! -d "${USER_SYNC_DIR}" ]; then
  rm -rf /tmp/ranger_usersync_inspect
  mkdir -p /tmp/ranger_usersync_inspect
  tar -xzf /export/packages/ranger/ranger-2.6.0-usersync.tar.gz -C /tmp/ranger_usersync_inspect
fi

echo "[admin-install-properties-220-520]"
sed -n '220,520p' "${ADMIN_DIR}/install.properties" \
  | sed -E 's/(password|PASSWORD|PassWord)=.*/\1=***/g'

echo "[admin-shell-files]"
find "${ADMIN_DIR}" -maxdepth 3 -type f -name "*.sh" -printf '%p\n' | sort | sed -n '1,120p'

echo "[usersync-shell-files]"
find "${USER_SYNC_DIR}" -maxdepth 3 -type f -name "*.sh" -printf '%p\n' | sort | sed -n '1,120p'

echo "[admin-config-grep]"
grep -RInE 'bind|6080|policymgr_external_url|ranger.service.host|ranger.service.http.port|server.port|ranger\.externalurl' "${ADMIN_DIR}" \
  | sed -n '1,160p' || true

echo "[usersync-config-grep]"
grep -RInE 'POLICY_MGR_URL|5151|listen|bind|service' "${USER_SYNC_DIR}" \
  | sed -n '1,160p' || true
