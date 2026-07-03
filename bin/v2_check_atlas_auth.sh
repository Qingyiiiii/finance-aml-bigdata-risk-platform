set -euo pipefail

ATLAS_URL="http://CLUSTER_NODE1_IP:21000"
ATLAS_USER="${ATLAS_ADMIN_USERNAME:-admin}"
ATLAS_PASSWORD="${ATLAS_ADMIN_PASSWORD:-}"

if [ -z "${ATLAS_PASSWORD}" ] && [ ! -t 0 ]; then
  while IFS='=' read -r key value; do
    case "${key}" in
      ATLAS_ADMIN_USERNAME) ATLAS_USER="${value}" ;;
      ATLAS_ADMIN_PASSWORD) ATLAS_PASSWORD="${value}" ;;
    esac
  done
fi

if [ -z "${ATLAS_PASSWORD}" ]; then
  echo "__ATLAS_PASSWORD_NOT_PROVIDED__"
  exit 2
fi

auth="$(printf '%s:%s' "${ATLAS_USER}" "${ATLAS_PASSWORD}" | base64 | tr -d '\n')"
cfg="$(mktemp)"
body="$(mktemp)"
trap 'rm -f "${cfg}" "${body}"' EXIT
chmod 600 "${cfg}" "${body}"
printf 'header = "Authorization: Basic %s"\n' "${auth}" > "${cfg}"

echo "[atlas-auth-check] version"
code="$(curl -sS --config "${cfg}" -o "${body}" -w '%{http_code}' --max-time 15 "${ATLAS_URL}/api/atlas/admin/version" || true)"
bytes="$(wc -c < "${body}" 2>/dev/null || echo 0)"
echo "path=/api/atlas/admin/version code=${code} bytes=${bytes}"
if [ "${code}" = "200" ]; then
  tr -d '\n' < "${body}" | sed -E 's/,"/,\n"/g' | head -n 20
  echo
fi

echo "[atlas-auth-check] status"
code="$(curl -sS --config "${cfg}" -o "${body}" -w '%{http_code}' --max-time 15 "${ATLAS_URL}/api/atlas/admin/status" || true)"
bytes="$(wc -c < "${body}" 2>/dev/null || echo 0)"
echo "path=/api/atlas/admin/status code=${code} bytes=${bytes}"
if [ "${code}" = "200" ]; then
  tr -d '\n' < "${body}" | head -c 500
  echo
fi

