set -euo pipefail

echo "[admin-install-properties-selected]"
sudo awk -F= '
  $1 ~ /^(setup_mode|PYTHON_COMMAND_INVOKER|DB_FLAVOR|SQL_CONNECTOR_JAR|db_host|db_name|db_user|audit_store|policymgr_external_url|authentication_method|unix_user|hadoop_conf|RANGER_ADMIN_LOG_DIR|RANGER_PID_DIR_PATH|JAVA_BIN)$/ {
    if ($1 ~ /password|PASSWORD|PassWord/) {
      print $1"=***"
    } else {
      print
    }
  }
' /export/server/ranger-admin/install.properties 2>/dev/null || true

echo "[usersync-install-properties-selected]"
sudo awk -F= '
  $1 ~ /^(POLICY_MGR_URL|SYNC_SOURCE|SYNC_INTERVAL|unix_user|unix_group|hadoop_conf|logdir|USERSYNC_PID_DIR_PATH)$/ {
    print
  }
' /export/server/ranger-usersync/install.properties 2>/dev/null || true
