set +e

echo "[probe] zookeeper 3.9.5"
curl -fsSL --connect-timeout 10 https://downloads.apache.org/zookeeper/zookeeper-3.9.5/ | sed -n '1,160p'

echo
echo "[probe] hbase 2.6.6"
curl -fsSL --connect-timeout 10 https://downloads.apache.org/hbase/2.6.6/ | sed -n '1,220p'

echo
echo "[probe] hbase 2.5.15"
curl -fsSL --connect-timeout 10 https://downloads.apache.org/hbase/2.5.15/ | sed -n '1,220p'

echo
echo "[probe] hudi 1.2.0"
curl -fsSL --connect-timeout 10 https://downloads.apache.org/hudi/1.2.0/ | sed -n '1,220p'
