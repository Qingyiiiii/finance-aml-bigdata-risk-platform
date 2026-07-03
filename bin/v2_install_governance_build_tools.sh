set -euo pipefail

echo "[governance-build-tools] host=$(hostname) user=$(whoami)"
echo "[dnf] install build dependencies"
sudo dnf -y install \
  maven \
  java-11-openjdk-devel \
  gcc \
  gcc-c++ \
  make \
  ant \
  unzip \
  zip \
  patch \
  lsof

echo "[versions]"
for c in mvn ant gcc g++ make java javac; do
  if command -v "$c" >/dev/null 2>&1; then
    printf '%s=' "$c"
    if [ "$c" = "ant" ]; then
      "$c" -version 2>&1 | head -n 1
    else
      "$c" --version 2>&1 | head -n 1
    fi
  fi
done

echo "[java homes]"
ls -ld /usr/lib/jvm/java-11* 2>/dev/null || true
ls -ld /usr/lib/jvm/java-17* 2>/dev/null || true

echo "[disk]"
df -h /export /tmp
