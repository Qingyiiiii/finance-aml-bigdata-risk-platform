set -euo pipefail

source /etc/profile.d/bigdata.sh 2>/dev/null || true
export JAVA_HOME=/export/server/jdk17
export PATH=/export/server/spark/bin:/export/server/hadoop/bin:/export/server/hadoop/sbin:$JAVA_HOME/bin:$PATH

echo "[spark] command paths"
command -v spark-submit || true
command -v spark-sql || true

echo "[spark] version"
spark-submit --version 2>&1 | sed -n '1,18p'

echo "[spark] jars"
find /export/server/spark/jars -maxdepth 1 -type f \( -name 'scala-library-*.jar' -o -name 'hudi-*.jar' \) -printf '%f\n' | sort

echo "[hadoop] namenode"
hdfs dfsadmin -safemode get || true
