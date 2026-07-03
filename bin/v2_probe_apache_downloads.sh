set +e

echo "[probe] zookeeper downloads"
curl -fsSL --connect-timeout 10 https://downloads.apache.org/zookeeper/ | sed -n '1,120p'

echo
echo "[probe] hbase downloads"
curl -fsSL --connect-timeout 10 https://downloads.apache.org/hbase/ | sed -n '1,160p'

echo
echo "[probe] hudi downloads"
curl -fsSL --connect-timeout 10 https://downloads.apache.org/hudi/ | sed -n '1,120p'
