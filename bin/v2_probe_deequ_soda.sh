set -euo pipefail

mkdir -p /tmp/finance_probe

echo "[deequ versions tail]"
curl -fsSL https://repo.maven.apache.org/maven2/com/amazon/deequ/deequ/maven-metadata.xml \
  -o /tmp/finance_probe/deequ-maven-metadata.xml
grep -o '<version>[^<]*</version>' /tmp/finance_probe/deequ-maven-metadata.xml | tail -n 20

echo "[deequ spark 3.5 candidates]"
grep -o '<version>[^<]*</version>' /tmp/finance_probe/deequ-maven-metadata.xml | grep 'spark-3.5' || true

echo "[soda pip index]"
python3.11 -m pip index versions soda-core 2>/dev/null | sed -n '1,20p' || true
