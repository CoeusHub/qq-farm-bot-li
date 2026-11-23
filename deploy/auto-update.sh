#!/usr/bin/env bash
# 自动更新脚本：检查 GHCR 上有没有新镜像，有就拉取并重建容器。
# 只访问 ghcr.io，不碰 Docker Hub，国内可用。
# 建议放到 /opt/qq-farm-bot/ 并加 crontab：
#   */5 * * * * /opt/qq-farm-bot/auto-update.sh >> /var/log/qq-farm-update.log 2>&1

set -euo pipefail

cd "$(dirname "$0")"

STAMP_FILE=".last-digest"
REMOTE_DIGEST="$(docker compose config --images 2>/dev/null | head -n1 | xargs -I{} \
  docker buildx imagetools inspect {} --format '{{.Manifest.Digest}}' 2>/dev/null || true)"

if [ -z "$REMOTE_DIGEST" ]; then
  echo "$(date '+%F %T') 无法获取远程镜像信息（网络问题？），跳过"
  exit 0
fi

if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$REMOTE_DIGEST" ]; then
  echo "$(date '+%F %T') 已是最新 ($REMOTE_DIGEST)"
  exit 0
fi

echo "$(date '+%F %T') 发现新镜像 $REMOTE_DIGEST，开始更新"
docker compose pull --quiet
docker compose up -d --quiet-pull
echo "$REMOTE_DIGEST" > "$STAMP_FILE"
docker image prune -f >/dev/null 2>&1 || true
echo "$(date '+%F %T') 更新完成"
