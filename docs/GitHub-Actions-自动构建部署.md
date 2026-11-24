# 用 GitHub Actions 自动构建 + 服务器只拉镜像

服务器 2 核 2G 跑 `pnpm build:web` 会 OOM 卡死，根因是 Vite 构建整个 Web 时内存峰值经常超过 1G，加上 Core 的 `tsc`，2G 机器上很容易被 OOM Killer 杀掉。
这套方案把编译全部搬到 GitHub 的机器上，服务器只下载一个编译好的镜像。

## 流水线做了什么

`.github/workflows/build-deploy.yml`：

1. 你 `git push` 到 `master`（或在 Actions 页面点 Run workflow）
2. GitHub 跑 `core/Dockerfile` 的多阶段构建 —— 里面已经包含 `pnpm -C web build` 和 `pnpm -C core build:ts`
3. 镜像推到 `ghcr.io/coeushub/qq-farm-bot-li`，打三个 tag：`latest`、`master`、`sha-xxxx`
4. （可选）SSH 到服务器执行 `docker compose pull && up -d`

服务器全程不编译，只拉取，内存占用跟跑一个 Node 服务差不多。

## 一次性配置

### 1. 仓库与 Actions

代码仓库：`CoeusHub/qq-farm-bot-li`（fork 自 `liyangpengs/qq-farm-bot`）。
Settings → Actions → General，确认允许 Action 运行。
`GITHUB_TOKEN` 的写权限不需要手动开，workflow 里已经声明了 `packages: write`。

### 2. 服务器准备 Docker

```bash
curl -fsSL https://get.docker.com | sh -s -- --mirror Aliyun
docker compose version
```

### 3. 服务器放 compose 文件

把仓库里的 `deploy/docker-compose.yml` 存到服务器 `/opt/qq-farm-bot/docker-compose.yml`（镜像名已写死为 `ghcr.io/coeushub/qq-farm-bot-li:latest`，不用改）：

```bash
mkdir -p /opt/qq-farm-bot && cd /opt/qq-farm-bot
curl -L -o docker-compose.yml https://raw.githubusercontent.com/CoeusHub/qq-farm-bot-li/master/deploy/docker-compose.yml
docker compose up -d
```

这个包已经从公开仓库推上去，匿名可拉，不需要 `docker login`。

如果服务器上还跑着裸 node 的旧实例，先停掉再起容器，否则 3007 端口会冲突：

```bash
bash /path/to/qq-farm-bot/stop.sh   # 或 kill 掉旧的 node core/client.js
```

### 4. 自动更新（cron 拉取，不用 Docker Hub）

`deploy/auto-update.sh` 每 5 分钟执行一次 `docker compose pull --quiet`（只拉 manifest 和变化的层），镜像变了再 `up -d` 重建容器；已是最新时几乎不产生流量。全程只访问 `ghcr.io`，不碰国内经常不可达的 Docker Hub。

```bash
cd /opt/qq-farm-bot
curl -L -o auto-update.sh https://raw.githubusercontent.com/CoeusHub/qq-farm-bot-li/master/deploy/auto-update.sh
chmod +x auto-update.sh
./auto-update.sh                 # 先手动跑一次，确认能正常判断和更新

/usr/bin/crontab -l 2>/dev/null | { cat; echo '*/5 * * * * /opt/qq-farm-bot/auto-update.sh >> /var/log/qq-farm-update.log 2>&1'; } | /usr/bin/crontab -
```

日志在 `/var/log/qq-farm-update.log`，每 5 分钟一行"检查完成"就说明在工作。

如果你更希望"push 完立刻部署"而不是等最多 5 分钟，再额外配下面这些 secret，deploy 步骤会 SSH 上来立即 pull + 重启：

| Secret | 说明 | 示例 |
| --- | --- | --- |
| `DEPLOY_HOST` | 服务器 IP | `1.2.3.4` |
| `DEPLOY_USER` | SSH 用户名 | `root` |
| `DEPLOY_PORT` | SSH 端口，可留空 | `22` |
| `DEPLOY_SSH_KEY` | 部署用的私钥全文 | `-----BEGIN OPENSSH PRIVATE KEY-----` |
| `DEPLOY_PATH` | 服务器上 compose 所在目录 | `/opt/qq-farm-bot` |

私钥在本地 `ssh-keygen -t ed25519 -C deploy -f deploy_key` 生成，公钥追加到服务器 `~/.ssh/authorized_keys`。

没配这些 secret 也不影响构建，deploy 步骤会打印"跳过自动部署"直接成功，更新交给 cron。

## 日常使用

改完代码：

```bash
git add -A && git commit -m "feat: xxx" && git push
```

构建通常 2~3 分钟（首次冷缓存 6~10 分钟），cron 在 5 分钟内把服务器换成新镜像。
查看进度：Actions 标签页 → Build & Deploy → 构建日志和镜像地址都在 summary 里。

## 回滚

每次构建都有 `sha-xxxxxxx` 的 tag。服务器上临时回到某个版本：

```bash
cd /opt/qq-farm-bot
docker compose down
sed -i 's|:latest|:sha-6a1b2c3|' docker-compose.yml
docker compose up -d
```

## 几个注意点

- 数据在 `qq-farm-data` 卷里，重建容器不会丢；`docker compose down -v` 才会删卷。
- 服务器镜像磁盘占用：旧镜像会堆，部署脚本里带了 `docker image prune -f`，只清悬空镜像。
- 想在服务器上保留裸跑 `start.sh` 的方式也可以，但那就还需要服务器编译，2G 机器依旧会卡；要用裸跑 + CI 的话得改成"CI 产出 dist + rsync 到服务器"，需要另加 workflow。
- 2C2G 建议顺手加 1G swap，避免偶发 OOM：`fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`，再写进 `/etc/fstab`。
