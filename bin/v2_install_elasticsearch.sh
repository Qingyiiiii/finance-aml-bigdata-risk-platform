set -euo pipefail

ES_VERSION=9.4.3
ES_TGZ="elasticsearch-${ES_VERSION}-linux-x86_64.tar.gz"
ES_URL="https://artifacts.elastic.co/downloads/elasticsearch/${ES_TGZ}"
ES_SHA_URL="${ES_URL}.sha512"
ES_HOME_VERSIONED="/export/server/elasticsearch-${ES_VERSION}"
ES_HOME="/export/server/elasticsearch"
ES_DATA="/export/data/elasticsearch"
ES_LOGS="/export/logs/elasticsearch"
ES_CERT_DIR="${ES_HOME}/config/certs"
ES_CREDENTIALS_FILE="$(mktemp /tmp/finance_es_credentials.XXXXXX)"

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
  echo "[elasticsearch] missing ELASTICSEARCH_ELASTIC_PASSWORD from stdin credentials" >&2
  exit 2
fi

echo "[elasticsearch] host=$(hostname) user=$(whoami)"
echo "[elasticsearch] version=${ES_VERSION}"

echo "[system] preparing kernel and package prerequisites"
sudo mkdir -p /export/packages /export/server "${ES_DATA}" "${ES_LOGS}"
sudo sysctl -w vm.max_map_count=262144 >/dev/null
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-finance-elasticsearch.conf >/dev/null
if ! command -v unzip >/dev/null 2>&1; then
  sudo dnf -y install unzip
fi

echo "[download] ${ES_URL}"
if [ ! -s "/export/packages/${ES_TGZ}" ]; then
  curl -fL --retry 3 --retry-delay 5 "${ES_URL}" -o "/export/packages/${ES_TGZ}"
else
  echo "[download] exists /export/packages/${ES_TGZ}"
fi

if [ ! -s "/export/packages/${ES_TGZ}.sha512" ]; then
  curl -fL --retry 3 --retry-delay 5 "${ES_SHA_URL}" -o "/export/packages/${ES_TGZ}.sha512"
fi

echo "[download] sha512 validation"
cd /export/packages
sha512sum -c "${ES_TGZ}.sha512"

echo "[install] extracting Elasticsearch"
if [ ! -d "${ES_HOME_VERSIONED}" ]; then
  tar -xzf "/export/packages/${ES_TGZ}" -C /export/server
fi
sudo ln -sfn "${ES_HOME_VERSIONED}" "${ES_HOME}"
sudo chown -R common:common "${ES_HOME_VERSIONED}" "${ES_DATA}" "${ES_LOGS}"
sudo chown -h common:common "${ES_HOME}"

echo "[config] writing elasticsearch.yml"
mkdir -p "${ES_HOME}/config/jvm.options.d" "${ES_CERT_DIR}"
cat > "${ES_HOME}/config/elasticsearch.yml" <<'EOF'
cluster.name: finance-bigdata-v2-elasticsearch
node.name: hadoop1
path.data: /export/data/elasticsearch
path.logs: /export/logs/elasticsearch
network.bind_host: ["127.0.0.1", "CLUSTER_NODE1_IP"]
network.publish_host: "CLUSTER_NODE1_IP"
http.port: 9200
transport.port: 9300
discovery.type: single-node
xpack.security.enabled: true
xpack.security.autoconfiguration.enabled: false
xpack.security.enrollment.enabled: false
xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.key: certs/hadoop1/hadoop1.key
xpack.security.http.ssl.certificate: certs/hadoop1/hadoop1.crt
xpack.security.http.ssl.certificate_authorities: ["certs/ca/ca.crt"]
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.key: certs/hadoop1/hadoop1.key
xpack.security.transport.ssl.certificate: certs/hadoop1/hadoop1.crt
xpack.security.transport.ssl.certificate_authorities: ["certs/ca/ca.crt"]
xpack.security.transport.ssl.verification_mode: certificate
EOF

cat > "${ES_HOME}/config/jvm.options.d/finance_v2.options" <<'EOF'
-Xms1g
-Xmx1g
EOF

echo "[cert] generating local CA and node certificate"
cd "${ES_HOME}"
if [ ! -f "${ES_CERT_DIR}/ca/ca.crt" ] || [ ! -f "${ES_CERT_DIR}/ca/ca.key" ]; then
  rm -rf "${ES_CERT_DIR}/ca" "${ES_CERT_DIR}/ca.zip"
  bin/elasticsearch-certutil ca --silent --pem --out "${ES_CERT_DIR}/ca.zip"
  unzip -oq "${ES_CERT_DIR}/ca.zip" -d "${ES_CERT_DIR}"
fi

cat > /tmp/finance_es_instances.yml <<'EOF'
instances:
  - name: hadoop1
    dns:
      - hadoop1
      - localhost
    ip:
      - 127.0.0.1
      - CLUSTER_NODE1_IP
EOF

if [ ! -f "${ES_CERT_DIR}/hadoop1/hadoop1.crt" ] || [ ! -f "${ES_CERT_DIR}/hadoop1/hadoop1.key" ]; then
  rm -rf "${ES_CERT_DIR}/hadoop1" "${ES_CERT_DIR}/hadoop1.zip"
  bin/elasticsearch-certutil cert \
    --silent \
    --pem \
    --in /tmp/finance_es_instances.yml \
    --ca-cert "${ES_CERT_DIR}/ca/ca.crt" \
    --ca-key "${ES_CERT_DIR}/ca/ca.key" \
    --out "${ES_CERT_DIR}/hadoop1.zip"
  unzip -oq "${ES_CERT_DIR}/hadoop1.zip" -d "${ES_CERT_DIR}"
fi
rm -f /tmp/finance_es_instances.yml
chmod 600 "${ES_CERT_DIR}/ca/ca.key" "${ES_CERT_DIR}/hadoop1/hadoop1.key"
chmod 644 "${ES_CERT_DIR}/ca/ca.crt" "${ES_CERT_DIR}/hadoop1/hadoop1.crt"

echo "[service] installing systemd service"
sudo tee /etc/systemd/system/elasticsearch-finance-v2.service >/dev/null <<'EOF'
[Unit]
Description=Finance BigData V2 Elasticsearch
After=network.target

[Service]
Type=forking
User=common
Group=common
WorkingDirectory=/export/server/elasticsearch
Environment=ES_HOME=/export/server/elasticsearch
Environment=ES_PATH_CONF=/export/server/elasticsearch/config
Environment=ES_JAVA_HOME=/export/server/elasticsearch/jdk
LimitNOFILE=65535
LimitNPROC=4096
ExecStart=/export/server/elasticsearch/bin/elasticsearch -d -p /export/server/elasticsearch/es.pid
PIDFile=/export/server/elasticsearch/es.pid
Restart=on-failure
TimeoutStartSec=180
TimeoutStopSec=180

[Install]
WantedBy=multi-user.target
EOF

echo "[firewall] allowing Elasticsearch ports from CLUSTER_SUBNET_CIDR"
for p in 9200 9300; do
  sudo firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"CLUSTER_SUBNET_CIDR\" port protocol=\"tcp\" port=\"${p}\" accept" >/dev/null || true
done
sudo firewall-cmd --reload >/dev/null || true

echo "[service] starting Elasticsearch"
sudo systemctl daemon-reload
sudo systemctl enable elasticsearch-finance-v2
sudo systemctl restart elasticsearch-finance-v2

echo "[elasticsearch] waiting for HTTPS readiness"
for i in $(seq 1 90); do
  ES_HTTP_CODE="$(
    curl -sS -o /tmp/finance_es_probe.json -w '%{http_code}' \
      --cacert "${ES_CERT_DIR}/ca/ca.crt" \
      https://127.0.0.1:9200 2>/dev/null || true
  )"
  if [ "${ES_HTTP_CODE}" = "200" ] || [ "${ES_HTTP_CODE}" = "401" ]; then
    break
  fi
  sleep 3
done

ES_HTTP_CODE="$(
  curl -sS -o /tmp/finance_es_probe.json -w '%{http_code}' \
    --cacert "${ES_CERT_DIR}/ca/ca.crt" \
    https://127.0.0.1:9200 2>/dev/null || true
)"
if [ "${ES_HTTP_CODE}" != "200" ] && [ "${ES_HTTP_CODE}" != "401" ]; then
  echo "[elasticsearch] startup did not become ready; recent log follows" >&2
  tail -n 120 "${ES_LOGS}/finance-bigdata-v2-elasticsearch.log" >&2 || true
  exit 3
fi

echo "[security] setting elastic built-in user password"
printf '%s\n%s\n' "${ELASTICSEARCH_ELASTIC_PASSWORD}" "${ELASTICSEARCH_ELASTIC_PASSWORD}" \
  | "${ES_HOME}/bin/elasticsearch-reset-password" \
      -u elastic \
      -i \
      -b \
      --url https://127.0.0.1:9200 \
      -E xpack.security.http.ssl.certificate_authorities="${ES_CERT_DIR}/ca/ca.crt" \
      -s >/dev/null

echo "[validation] authenticated cluster response"
curl -fsS --cacert "${ES_CERT_DIR}/ca/ca.crt" \
  -u "elastic:${ELASTICSEARCH_ELASTIC_PASSWORD}" \
  https://127.0.0.1:9200
echo

echo "[validation] cluster health"
curl -fsS --cacert "${ES_CERT_DIR}/ca/ca.crt" \
  -u "elastic:${ELASTICSEARCH_ELASTIC_PASSWORD}" \
  https://127.0.0.1:9200/_cluster/health
echo

echo "[validation] create finance investigation index"
curl -fsS --cacert "${ES_CERT_DIR}/ca/ca.crt" \
  -u "elastic:${ELASTICSEARCH_ELASTIC_PASSWORD}" \
  -X PUT https://127.0.0.1:9200/finance-risk-events-v2 \
  -H 'Content-Type: application/json' \
  -d '{
    "settings": {
      "number_of_replicas": 0
    },
    "mappings": {
      "properties": {
        "transaction_id": {"type": "keyword"},
        "account_number": {"type": "keyword"},
        "event_time": {"type": "date"},
        "risk_level": {"type": "keyword"},
        "risk_score": {"type": "double"},
        "rule_hits": {"type": "keyword"},
        "amount_paid": {"type": "double"},
        "payment_currency": {"type": "keyword"},
        "investigation_text": {"type": "text"}
      }
    }
  }' || true
echo

curl -fsS --cacert "${ES_CERT_DIR}/ca/ca.crt" \
  -u "elastic:${ELASTICSEARCH_ELASTIC_PASSWORD}" \
  -X PUT https://127.0.0.1:9200/finance-risk-events-v2/_settings \
  -H 'Content-Type: application/json' \
  -d '{"index":{"number_of_replicas":0}}'
echo

curl -fsS --cacert "${ES_CERT_DIR}/ca/ca.crt" \
  -u "elastic:${ELASTICSEARCH_ELASTIC_PASSWORD}" \
  'https://127.0.0.1:9200/_cat/indices?v'

echo "[validation] listening ports"
ss -lntp | grep -E '9200|9300' || true

echo "[service] status"
sudo systemctl --no-pager --full status elasticsearch-finance-v2 | sed -n '1,18p'

