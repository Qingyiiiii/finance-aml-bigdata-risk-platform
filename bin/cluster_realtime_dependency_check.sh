#!/usr/bin/env bash
# Purpose: 实时依赖排查脚本，检查 Flink lib、Kafka CLI、Python 模块和当前实时进程。
# Boundary: 只读检查，不安装依赖、不启动服务。
set -u

echo "===== flink lib connectors ====="
ls -1 /export/server/flink/lib | egrep -i 'kafka|json|redis|connector' || true

echo "===== kafka cli version ====="
export JAVA_HOME=/export/server/jdk17
export PATH=$JAVA_HOME/bin:$PATH
/export/server/kafka/bin/kafka-topics.sh --version 2>/dev/null || true

echo "===== python modules ====="
PYTHON_BIN=$(command -v python3 || command -v python || true)
if [[ -n "$PYTHON_BIN" ]]; then
  "$PYTHON_BIN" --version
  "$PYTHON_BIN" - <<'PY'
import importlib.util
# 逐个模块输出 True/False，便于判断是否要走无依赖 socket/RESP 方案。
for module in ["redis", "kafka", "pyflink"]:
    print(f"{module}={importlib.util.find_spec(module) is not None}")
PY
fi

echo "===== current realtime processes ====="
jps -l | egrep 'kafka.Kafka|StandaloneSessionClusterEntrypoint|TaskManagerRunner' || true
ss -lntp | egrep '9092|9093|6379|8081' || true
