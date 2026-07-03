set -euo pipefail

echo "[usersync-status]"
sudo systemctl status finance-ranger-usersync --no-pager -l || true

echo "[usersync-journal]"
sudo journalctl -u finance-ranger-usersync --no-pager -n 120 || true

echo "[usersync-logs]"
for f in /export/logs/ranger/usersync/setup.log /export/logs/ranger/usersync/auth.log /export/server/ranger-usersync/logfile; do
  echo "--- $f"
  if sudo test -f "$f"; then
    sudo tail -n 160 "$f" | sed -E 's/(password|PASSWORD|PassWord)([[:space:]]*[:=][[:space:]]*)[^[:space:]]+/\1\2***/g'
  else
    echo "missing"
  fi
done

echo "[usersync-processes]"
ps -eo pid,ppid,etime,comm,args --no-headers | awk '/[D]proc_rangerusersync|UnixAuthenticationService/ {print}' || true

echo "[listeners]"
ss -lntp | awk '$4 ~ /:5151$/ || $4 ~ /:6080$/ {print}' || true
