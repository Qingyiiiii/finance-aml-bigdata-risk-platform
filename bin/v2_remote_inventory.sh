set +e

printf 'HOST\t'
hostname
printf 'WHOAMI\t'
whoami
printf 'DATE\t'
date '+%F %T %Z'

printf '\n[local paths]\n'
ls -ld /export/server /export/data /export/packages /lakehouse/projects /home/common/tmp 2>/dev/null

printf '\n[service links]\n'
for p in hadoop hive spark flink kafka trino flink-cdc prometheus grafana doris zookeeper hbase opensearch; do
  if [ -e /export/server/$p ] || [ -L /export/server/$p ]; then
    printf '%s\t' "$p"
    readlink -f /export/server/$p 2>/dev/null || ls -ld /export/server/$p
  else
    printf '%s\tMISSING\n' "$p"
  fi
done

printf '\n[package samples]\n'
find /export/packages -maxdepth 1 -type f | sed 's#^#/##' | head -n 80

printf '\n[cluster resources]\n'
for h in hadoop1 hadoop2 hadoop3; do
  echo "===== $h ====="
  ssh -o BatchMode=yes -o ConnectTimeout=5 common@$h 'hostname; df -h /export 2>/dev/null; free -h; jps 2>/dev/null | sort' 2>&1
done

printf '\n[sudo check]\n'
sudo -n true >/dev/null 2>&1
echo "sudo_no_password=$?"

printf '\n[network check]\n'
curl -I --connect-timeout 8 https://packages.clickhouse.com/rpm/clickhouse.repo 2>&1 | head -n 8
curl -I --connect-timeout 8 https://artifacts.opensearch.org/ 2>&1 | head -n 8
