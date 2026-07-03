set -euo pipefail

echo "[python candidates]"
for c in python3.13 python3.12 python3.11 python3.10 python3 python; do
  if command -v "$c" >/dev/null 2>&1; then
    printf '%s ' "$c"
    "$c" --version
  fi
done

echo "[os]"
sed -n '1,6p' /etc/os-release
