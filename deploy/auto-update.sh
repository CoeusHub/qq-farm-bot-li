#!/usr/bin/env bash
# 自动更新脚本：检查 GHCR 上有没有新镜像，有就拉取并重建容器。
# 只访问 ghcr.io，不碰 Docker Hub，国内可用。
# 已是最新时只拉取 manifest，几乎不产生流量。
# 用法：/opt/qq-farm-bot/auto-update.sh，配合 crontab 每 5 分钟一次

set -euo pipefail

cd "$(dirname "$0")"

if ! docker compose pull --quiet; then
  echo "$(date '+%F %T') 拉取失败（多半是网络问题），保留当前容器不动"
  exit 0
fi

# 镜像没变时 up -d 是空操作；变了才会重建容器，数据卷不受影响
docker compose up -d
docker image prune -f >/dev/null 2>&1 || true

echo "$(date '+%F %T') 检查完成 $(docker compose images --format '{{.ID}}' 2>/dev/null | head -n1)"
