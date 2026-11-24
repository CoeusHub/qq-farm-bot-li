#!/usr/bin/env bash
# 服务器端更新脚本（pm2 裸跑方案）：只拉 GitHub 构建好的快照，不编译。
# 用法：
#   APP_DIR=/var/www/farm-bot/qq-farm-bot-li ./update-artifact.sh
# 建议 crontab：
#   */30 * * * * APP_DIR=/var/www/farm-bot/qq-farm-bot-li /var/www/farm-bot/qq-farm-bot-li/deploy/update-artifact.sh >> /var/log/qq-farm-artifact.log 2>&1

set -euo pipefail

APP_DIR="${APP_DIR:-/var/www/farm-bot/qq-farm-bot-li}"
PM2_NAME="${PM2_NAME:-qq-farm-bot}"

cd "$APP_DIR"

git fetch --depth=1 origin dist
REMOTE="$(git rev-parse origin/dist)"

if [ "$(git rev-parse HEAD 2>/dev/null || echo none)" = "$REMOTE" ] \
  && [ -d core/node_modules/@qq-farm-bot/session-contract ]; then
  echo "$(date '+%F %T') 已是最新 ${REMOTE:0:7}"
  exit 0
fi

# 依赖声明变了才安装；node_modules 缺失/为空时也必须重装
LOCK_OLD="$(git rev-parse HEAD:pnpm-lock.yaml 2>/dev/null || true)"
git checkout -B runtime "$REMOTE" --force
LOCK_NEW="$(git rev-parse HEAD:pnpm-lock.yaml 2>/dev/null || true)"

NEED_INSTALL=0
[ -n "$(ls -A node_modules 2>/dev/null || true)" ] || NEED_INSTALL=1
[ -d core/node_modules ] || NEED_INSTALL=1
[ -d packages/session-contract/node_modules ] || NEED_INSTALL=1
[ "$LOCK_OLD" = "$LOCK_NEW" ] || NEED_INSTALL=1

if [ "$NEED_INSTALL" = "1" ]; then
  echo "$(date '+%F %T') 安装生产依赖（node_modules 缺失或依赖有变化）"
  pnpm install --frozen-lockfile --prod --prefer-offline
fi

# 缺依赖就别重启，直接报错退出，避免 pm2 反复拉起失败进程
# 注意 workspace 布局：核心依赖的链接在 core/node_modules，不在根 node_modules
if [ ! -d core/node_modules/@qq-farm-bot/session-contract ]; then
  echo "$(date '+%F %T') 错误：core/node_modules/@qq-farm-bot/session-contract 未建立，请检查 pnpm install 输出" >&2
  exit 1
fi

# core/data 是用户数据，被 .gitignore 忽略，checkout 不会动它
if pm2 describe "$PM2_NAME" >/dev/null 2>&1; then
  pm2 restart "$PM2_NAME" --update-env
else
  pm2 start core/client.js --name "$PM2_NAME" --cwd "$APP_DIR"
fi
pm2 save >/dev/null 2>&1 || true

echo "$(date '+%F %T') 已更新到 ${REMOTE:0:7} 并重启 $PM2_NAME"
