set -euo pipefail

for url in \
  https://downloads.apache.org/ranger/2.6.0/ \
  https://downloads.apache.org/atlas/2.5.0/; do
  echo "URL=$url"
  curl -fsSL "$url" | grep -E 'href="[^"]+\.(tar\.gz|tgz|zip|sha512|asc)"' | sed -n '1,80p'
done
