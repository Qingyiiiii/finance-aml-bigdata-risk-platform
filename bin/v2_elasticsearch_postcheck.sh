set -euo pipefail

ES_HOME="/export/server/elasticsearch"
ES_CA="${ES_HOME}/config/certs/ca/ca.crt"
ES_CREDENTIALS_FILE="$(mktemp /tmp/finance_es_postcheck_credentials.XXXXXX)"

cleanup_credentials() {
  shred -u "${ES_CREDENTIALS_FILE}" >/dev/null 2>&1 || rm -f "${ES_CREDENTIALS_FILE}"
}
trap cleanup_credentials EXIT

chmod 600 "${ES_CREDENTIALS_FILE}"
cat > "${ES_CREDENTIALS_FILE}"
set -a
source "${ES_CREDENTIALS_FILE}"
set +a

if [ -z "${ELASTICSEARCH_ELASTIC_PASSWORD:-}" ]; then
  echo "[elasticsearch-postcheck] missing ELASTICSEARCH_ELASTIC_PASSWORD from stdin credentials" >&2
  exit 2
fi

echo "[elasticsearch-postcheck] service"
sudo systemctl --no-pager --full status elasticsearch-finance-v2 | sed -n '1,12p'

echo "[elasticsearch-postcheck] unauthenticated request should be rejected"
UNAUTH_CODE="$(
  curl -sS -o /tmp/finance_es_unauth.json -w '%{http_code}' \
    --cacert "${ES_CA}" \
    https://CLUSTER_NODE1_IP:9200 2>/dev/null || true
)"
echo "unauthenticated_http_code=${UNAUTH_CODE}"

echo "[elasticsearch-postcheck] set single-node replica policy for V2 index"
curl -fsS --cacert "${ES_CA}" \
  -u "elastic:${ELASTICSEARCH_ELASTIC_PASSWORD}" \
  -X PUT https://127.0.0.1:9200/finance-risk-events-v2/_settings \
  -H 'Content-Type: application/json' \
  -d '{"index":{"number_of_replicas":0}}'
echo

echo "[elasticsearch-postcheck] authenticated cluster health"
curl -fsS --cacert "${ES_CA}" \
  -u "elastic:${ELASTICSEARCH_ELASTIC_PASSWORD}" \
  'https://127.0.0.1:9200/_cluster/health?wait_for_status=green&timeout=30s'
echo

echo "[elasticsearch-postcheck] indices"
curl -fsS --cacert "${ES_CA}" \
  -u "elastic:${ELASTICSEARCH_ELASTIC_PASSWORD}" \
  'https://127.0.0.1:9200/_cat/indices?v'

echo "[elasticsearch-postcheck] listening ports"
ss -lntp | grep -E '9200|9300' || true

