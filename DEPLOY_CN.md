# CN API Docker 部署手册

在 Linux 服务器上用 Docker 部署一个自托管的 CN 区 FGO game data API。
API 镜像在服务器上本地 `docker build`，不依赖任何 CI workflow。

## 0. 服务器要求

- Docker Engine 24+ 与 Docker Compose v2（`docker compose` 子命令可用）
- 内存 ≥ 4 GB（首次导入 CN 数据 + 构建 PGroonga 全文索引峰值约 2~4 GB）
- 磁盘 ≥ 10 GB（gamedata 仓库 + Postgres 数据卷）
- 可访问外网：`git.atlasacademy.io`（gamedata 仓库）、`assets.atlasacademy.io`（asset manifest）、PyPI（构建镜像时装依赖）

## 1. 获取项目

```sh
git clone https://github.com/xiaoshadan/fgo-game-data-api.git
cd fgo-game-data-api
```

## 2. 准备配置

```sh
cp config.docker.json config.json
```

编辑 `config.json`，**必须**修改：

| 字段 | 说明 |
| --- | --- |
| `github_webhook_secret` | 改成任意随机字符串（如 `openssl rand -hex 16` 生成）。它既是触发数据更新的 URL 路径，也是首次自动导入的开关 |

可选调整：

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `export_all_nice` | `false` | 改为 `true` 会在导入后生成 `/export` 静态全量文件（首次导入时间明显变长，但之后查询更快更省资源） |
| `skip_script_fulltext` | `false` | 内存紧张时可设为 `true`，跳过剧本全文索引（`/raw/` 剧本搜索不可用） |
| `openapi_url` | `null` | 对外提供服务的公网地址（如 `https://fgo-api.example.com`），只影响文档里展示的 server URL |

> `config.json` 已在 `.gitignore` 中，不会被提交。数据库口令如需修改，同步改 `config.docker.json` → `config.json` 中 `postgresdsn` 与 compose 里 `POSTGRES_PASSWORD` 两处。

## 3. 构建并启动

```sh
docker compose -f docker-compose.sample.yml up -d --build
```

首次启动流程（自动完成）：

1. `pg-fgoapicn`（PGroonga Postgres）与 `redis` 启动并通过 healthcheck；
2. `api` 容器等待两者就绪后，把 CN 分支 gamedata 克隆到 `gamedata-cn` 卷（`/data/fgo-game-data-cn`）；
3. entrypoint 调用本机 webhook 端点触发首次数据导入（`AUTO_UPDATE_ON_START=1`）。

观察导入进度：

```sh
docker compose -f docker-compose.sample.yml logs -f api
```

看到 `Loaded game data in ...` / `Cleared ... cache redis keys` 即导入完成。首次导入通常需要 10~30 分钟（取决于磁盘与网络）。

验证：

```sh
curl http://localhost:8000/info
# 应返回 {"CN": {"hash": "...", "timestamp": ...}}
```

浏览器打开 `http://<服务器IP>:8000/docs` 查看 API 文档。

## 4. 日常运维

### 4.1 更新游戏数据（gamedata 有新提交时）

这是一个 HTTP POST 请求，作用是"通知 API 容器：gamedata 有新版本了，请在后台拉取并重新导入"。它对应代码里的 [`update_gamedata()`](app/routers/secret.py:42) 端点。

**URL 里的 `<github_webhook_secret>` 是什么？**

就是你在第 2 步 `config.json` 里设置的那个 `github_webhook_secret` 字符串。它被用作 URL 的一部分，相当于一个简易口令——不知道这个字符串的人无法触发你的数据更新。例如你设置的是 `abc123`，那么实际 URL 就是 `http://localhost:8000/abc123/update`。

**手动触发（SSH 到服务器上执行）**

```sh
# 把 abc123 换成你 config.json 里的 github_webhook_secret
curl -X POST http://localhost:8000/abc123/update \
     -H "Content-Type: application/json" \
     -d '{"ref": "refs/heads/CN"}'
```

参数说明：

| 部分 | 含义 |
| --- | --- |
| `-X POST` | 该端点只接受 POST 请求 |
| `-H "Content-Type: application/json"` | 请求体是 JSON 格式 |
| `-d '{"ref": "refs/heads/CN"}'` | 告诉 API 这次更新对应 gamedata 仓库的 CN 分支（`ref` 是 git 分支引用的标准写法）。省略整个 `-d` 参数也可以，那样会更新 config 里配置的所有区 |

执行后立即返回一段 JSON（表示"已受理"），实际拉取和导入在后台进行，用 `docker compose -f docker-compose.sample.yml logs -f api` 观察进度。

**自动触发（推荐，配一次就不用管）**

把上面的 URL 配置成 GitHub webhook，让上游 gamedata 更新时 GitHub 主动来调用：

1. 打开你的 gamedata fork 仓库（如 `https://github.com/xiaoshadan/fgo-game-data`）→ Settings → Webhooks → Add webhook；
2. Payload URL 填 `http://<服务器公网IP或域名>:8000/abc123/update`；
3. Content type 选 `application/json`；
4. Trigger on 选 "Just the push event"（或按需选分支过滤）；
5. Add webhook。

之后每次该仓库有 push，GitHub 就会 POST 这个 URL，API 自动完成拉取 + 导入，无需人工干预。

> 注意：webhook 需要 GitHub 能访问到你的服务器（是 GitHub 主动 POST 过来，方向为入站）。如果服务器在内网，见下面的替代方案。

**内网服务器替代方案：cron 定时轮询（推荐）**

webhook 是 GitHub 主动找你（入站），内网不可行；但服务器主动找 GitHub（出站，如 `git pull`）不受影响。因此可以在服务器上用 cron 定时触发更新，效果接近自动：

```sh
# 在服务器上执行 crontab -e，添加一行（每 2 小时检查一次更新）：
0 */2 * * * curl -s -X POST http://localhost:8000/<github_webhook_secret>/update -H "Content-Type: application/json" -d '{"ref": "refs/heads/CN"}' > /dev/null 2>&1
```

说明：

- `curl localhost` 是本机请求，不需要任何公网入口；
- 即使 gamedata 没有新提交，重复触发也无害（`git pull` 无变化时导入的数据相同，只是白跑一次导入流程，约几分钟）；
- 想省资源可以拉长间隔（每天一次：`0 3 * * *`）。

其他可选方案：

| 方案 | 适用场景 |
| --- | --- |
| 内网穿透（frp / cloudflare tunnel / ngrok） | 想保留 GitHub webhook 实时触发 |
| cron 定时 curl（上面的方案） | 内网、能出站访问 GitHub，最简单 |
| 手动 SSH 执行 curl | 更新频率低，人工可控 |

### 4.2 更新 API 代码（上游 fgo-game-data-api 有新提交时）

```sh
git pull
docker compose -f docker-compose.sample.yml up -d --build api
```

只重建 `api` 服务，Postgres/Redis 数据不受影响。导入过的数据保留在卷中，重启后不会重复导入（除非 gamedata 版本变化触发更新）。

### 4.3 常用命令

```sh
# 查看各容器状态（api 应为 healthy）
docker compose -f docker-compose.sample.yml ps

# 重启 api
docker compose -f docker-compose.sample.yml restart api

# 手动触发一次完整重导入（不 git pull）
docker compose -f docker-compose.sample.yml exec api \
    python -c "import asyncio; from app.db.engine import async_engines; from app.redis import Redis; from redis.asyncio import Redis as R; from app.tasks import load_and_export; from app.config import Settings; s=Settings(); asyncio.run(load_and_export(R.from_url(str(s.redisdsn)), {k: v.gamedata for k,v in s.data.items()}, async_engines, False))"

# 完全重置（删除所有数据卷，慎用）
docker compose -f docker-compose.sample.yml down -v
```

### 4.4 日志与排错

| 现象 | 排查 |
| --- | --- |
| `api` 一直 restarting | `docker compose logs api` 看报错；常见为 `config.json` 挂载路径不对或 JSON 语法错误 |
| `/info` 返回 `{}` | gamedata 克隆失败或没有 `.git`；进容器 `docker compose exec api ls /data/fgo-game-data-cn` 检查 |
| 首次导入 OOM | 调大服务器内存，或设 `skip_script_fulltext: true`、`export_all_nice: false` |
| 端口冲突 | 改 compose 里 `ports: "8000:8000"` 左侧的宿主端口 |

## 5. 文件清单

| 文件 | 作用 |
| --- | --- |
| [`Dockerfile`](/Dockerfile) | Python 3.13-slim + git + libpq 镜像；构建时把 API 仓库自身 git 元数据打进镜像（`/info` 与 `/docs` 依赖它） |
| [`.dockerignore`](/.dockerignore) | 缩小构建上下文 |
| [`docker-entrypoint.sh`](/docker-entrypoint.sh) | 等待 PG/Redis 就绪 → 首次克隆 CN gamedata → 可选触发首次导入 → 启动 gunicorn |
| [`gunicorn.conf.py`](/gunicorn.conf.py) | gunicorn + UvicornWorker 配置（默认 1 worker，可用 `WEB_CONCURRENCY` 调整） |
| [`config.docker.json`](/config.docker.json) | CN 单区配置模板，DSN 指向 compose 服务名 |
| [`docker-compose.sample.yml`](/docker-compose.sample.yml) | postgres + redis + api 三服务编排，含 healthcheck 与依赖顺序 |

## 6. 架构说明

```
浏览器/GitHub webhook
        │
        ▼ :8000
┌─────────────── api 容器 ───────────────┐
│ entrypoint → gunicorn → uvicorn worker │
│   app.main:app (FastAPI)               │
│   /data/fgo-game-data-cn (gamedata 卷) │
└──────┬─────────────────────┬───────────┘
       │ :5432               │ :6379
┌──────▼─────────┐   ┌───────▼────────┐
│ pg-fgoapicn    │   │ redis          │
│ PGroonga 14    │   │ 缓存 + 反查索引 │
│ 卷: pg-cn-data │   │ 卷: redis-data │
└────────────────┘   └────────────────┘
```

数据流：gamedata git 仓库（JSON 文件）→ 导入脚本（[`app/tasks.py`](app/tasks.py) `load_and_export`）→ Postgres（原始表 + PGroonga 全文索引）与 Redis（反查索引、版本号）→ API 查询时按需组装返回。
