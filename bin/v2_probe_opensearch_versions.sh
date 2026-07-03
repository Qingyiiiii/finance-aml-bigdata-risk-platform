set +e

for v in 3.6.0 3.5.0 3.4.0 3.3.2 3.3.1 3.3.0 3.2.0 3.1.0 3.0.0; do
  url="https://artifacts.opensearch.org/releases/bundle/opensearch/$v/opensearch-$v-linux-x64.tar.gz"
  printf '[probe] %s ' "$url"
  code=$(curl -L -I --connect-timeout 10 --max-time 20 -o /dev/null -s -w '%{http_code}' "$url")
  echo "$code"
done
