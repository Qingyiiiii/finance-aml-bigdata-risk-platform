#!/usr/bin/env bash
# Purpose: 启动 PostgreSQL，供 Hive Metastore 使用。
# Boundary: 只启动/检查 PostgreSQL 服务，不修改数据库 schema。
set -u

echo "===== start postgresql ====="
sudo -S -p '' systemctl start postgresql || sudo -S -p '' systemctl start postgresql-15

echo "===== check postgresql ====="
sudo -S -p '' systemctl status postgresql --no-pager || sudo -S -p '' systemctl status postgresql-15 --no-pager
ss -lntp | grep 5432 || true
sudo -S -p '' -u postgres psql -c "\\l"
