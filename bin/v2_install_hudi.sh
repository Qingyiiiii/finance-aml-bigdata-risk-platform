set -euo pipefail

source /etc/profile.d/bigdata.sh 2>/dev/null || true
export JAVA_HOME=/export/server/jdk17
export PATH=/export/server/spark/bin:/export/server/hadoop/bin:/export/server/hadoop/sbin:$JAVA_HOME/bin:$PATH

HUDI_VERSION=1.2.0
SPARK_MINOR=3.5
SCALA_BINARY=2.12
HUDI_JAR="hudi-spark${SPARK_MINOR}-bundle_${SCALA_BINARY}-${HUDI_VERSION}.jar"
HUDI_MAVEN_PATH="org/apache/hudi/hudi-spark${SPARK_MINOR}-bundle_${SCALA_BINARY}/${HUDI_VERSION}/${HUDI_JAR}"
HUDI_URL="https://repo.maven.apache.org/maven2/${HUDI_MAVEN_PATH}"
HUDI_PACKAGE="/export/packages/${HUDI_JAR}"
HUDI_SPARK_JAR="/export/server/spark/jars/${HUDI_JAR}"
HUDI_HDFS_ROOT="/lakehouse/projects/finance_bigdata/hudi"
HUDI_SMOKE_PATH="${HUDI_HDFS_ROOT}/account_state_hudi_smoke"
HUDI_WORK_DIR="/home/common/tmp/finance_bigdata_project/v2_hudi"
HUDI_SMOKE_SCRIPT="${HUDI_WORK_DIR}/hudi_finance_smoke.py"
HUDI_SMOKE_RESULT="${HUDI_WORK_DIR}/hudi_finance_smoke_result.json"

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10"

echo "[hudi] host=$(hostname) user=$(whoami)"
echo "[hudi] target jar=${HUDI_JAR}"

echo "[spark] version"
spark-submit --version 2>&1 | sed -n '1,10p'

echo "[download] ${HUDI_URL}"
mkdir -p /export/packages "${HUDI_WORK_DIR}"
if [ ! -s "${HUDI_PACKAGE}" ]; then
  curl -fL --retry 3 --retry-delay 5 "${HUDI_URL}" -o "${HUDI_PACKAGE}"
else
  echo "[download] exists ${HUDI_PACKAGE}"
fi

echo "[install] copy jar to hadoop1 Spark jars"
cp "${HUDI_PACKAGE}" "${HUDI_SPARK_JAR}"

echo "[install] distribute jar to hadoop2/hadoop3"
for h in hadoop2 hadoop3; do
  scp ${SSH_OPTS} "${HUDI_SPARK_JAR}" "common@${h}:${HUDI_SPARK_JAR}"
done

echo "[hdfs] preparing Hudi root"
hdfs dfs -mkdir -p "${HUDI_HDFS_ROOT}"

echo "[smoke] writing PySpark Hudi upsert smoke"
cat > "${HUDI_SMOKE_SCRIPT}" <<'PY'
from __future__ import annotations

import json
from pathlib import Path

from pyspark.sql import SparkSession


BASE_PATH = "hdfs:///lakehouse/projects/finance_bigdata/hudi/account_state_hudi_smoke"
RESULT_PATH = Path("/home/common/tmp/finance_bigdata_project/v2_hudi/hudi_finance_smoke_result.json")
RESULT_PATH.parent.mkdir(parents=True, exist_ok=True)


def main() -> int:
    spark = (
        SparkSession.builder.appName("finance-v2-hudi-smoke")
        .config("spark.serializer", "org.apache.spark.serializer.KryoSerializer")
        .config("spark.sql.extensions", "org.apache.spark.sql.hudi.HoodieSparkSessionExtension")
        .config("spark.sql.catalog.spark_catalog", "org.apache.spark.sql.hudi.catalog.HoodieCatalog")
        .config("spark.kryo.registrator", "org.apache.spark.HoodieSparkKryoRegistrar")
        .getOrCreate()
    )
    spark.sparkContext.setLogLevel("WARN")

    table_name = "account_state_hudi_smoke"
    common_options = {
        "hoodie.table.name": table_name,
        "hoodie.datasource.write.recordkey.field": "account_number",
        "hoodie.datasource.write.precombine.field": "source_event_time",
        "hoodie.datasource.write.table.type": "COPY_ON_WRITE",
    }

    initial_rows = [
        ("acct-001", "LOW", 0.12, "2026-07-01 08:00:00", "2026-07-01 08:00:00"),
        ("acct-002", "MEDIUM", 0.51, "2026-07-01 08:01:00", "2026-07-01 08:01:00"),
        ("acct-003", "HIGH", 0.92, "2026-07-01 08:02:00", "2026-07-01 08:02:00"),
    ]
    columns = [
        "account_number",
        "risk_level",
        "risk_score",
        "updated_at",
        "source_event_time",
    ]
    initial_df = spark.createDataFrame(initial_rows, columns)
    initial_df.write.format("hudi").options(**common_options).mode("overwrite").save(BASE_PATH)

    update_rows = [
        ("acct-002", "HIGH", 0.88, "2026-07-01 08:05:00", "2026-07-01 08:05:00"),
        ("acct-004", "LOW", 0.18, "2026-07-01 08:06:00", "2026-07-01 08:06:00"),
    ]
    update_df = spark.createDataFrame(update_rows, columns)
    update_df.write.format("hudi").options(**common_options).option(
        "hoodie.datasource.write.operation", "upsert"
    ).mode("append").save(BASE_PATH)

    result_df = spark.read.format("hudi").load(BASE_PATH)
    selected = [
        row.asDict()
        for row in result_df.select(
            "account_number", "risk_level", "risk_score", "source_event_time"
        )
        .orderBy("account_number")
        .collect()
    ]
    acct_002 = [row for row in selected if row["account_number"] == "acct-002"][0]

    summary = {
        "component": "Apache Hudi",
        "base_path": BASE_PATH,
        "row_count_after_upsert": len(selected),
        "acct_002_risk_level": acct_002["risk_level"],
        "acct_002_risk_score": acct_002["risk_score"],
        "records": selected,
        "success": len(selected) == 4
        and acct_002["risk_level"] == "HIGH"
        and float(acct_002["risk_score"]) == 0.88,
    }
    RESULT_PATH.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    spark.stop()
    return 0 if summary["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
PY

chmod 700 "${HUDI_SMOKE_SCRIPT}"

echo "[smoke] clean previous Hudi smoke path"
hdfs dfs -rm -r -skipTrash "${HUDI_SMOKE_PATH}" >/dev/null 2>&1 || true

echo "[smoke] run PySpark Hudi upsert validation"
spark-submit \
  --master local[2] \
  --jars "${HUDI_SPARK_JAR}" \
  --conf spark.executor.instances=1 \
  --conf spark.executor.cores=1 \
  --conf spark.executor.memory=1g \
  --conf spark.executor.memoryOverhead=512m \
  --conf spark.driver.memory=1g \
  --conf spark.sql.shuffle.partitions=2 \
  --conf spark.serializer=org.apache.spark.serializer.KryoSerializer \
  --conf spark.sql.extensions=org.apache.spark.sql.hudi.HoodieSparkSessionExtension \
  --conf spark.sql.catalog.spark_catalog=org.apache.spark.sql.hudi.catalog.HoodieCatalog \
  --conf spark.kryo.registrator=org.apache.spark.HoodieSparkKryoRegistrar \
  "${HUDI_SMOKE_SCRIPT}"

echo "[validation] Hudi result file"
cat "${HUDI_SMOKE_RESULT}"
echo

echo "[validation] HDFS files"
hdfs dfs -ls -R "${HUDI_SMOKE_PATH}" | sed -n '1,80p'

echo "[validation] jar distribution"
for h in hadoop1 hadoop2 hadoop3; do
  ssh ${SSH_OPTS} "common@${h}" "ls -lh '${HUDI_SPARK_JAR}'"
done

echo "[hudi] done"
