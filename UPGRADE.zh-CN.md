# 升级迁移指南：从 1.x 升级到当前版本

本指南帮助从之前的 TeslaMate 版本升级而来的用户理解默认行为变化，以及如何安全启用或回退新增功能。升级前必须备份数据库并记录旧提交。

## 概览

| 行为 | 之前 | 默认（升级后） | 启用新版 |
|---|---|---|---|
| TeslaMate 页面是否强制登录才能访问设置/地理围栏 | 否 | 否（保持兼容） | `TESLAMATE_STRICT_AUTH=true` |
| `POST/GET /api/car/*/logging/{resume,suspend}` 是否检查登录态 | 否 | 否 | `TESLAMATE_PROTECT_API=true` |
| Grafana 端口 `3000` 是否对公网监听 | 是（旧 compose） | 否（仅 `127.0.0.1:3000`） | 通过 HTTPS 反向代理访问 |
| Grafana 认证方式 | 可能依赖 `/dashboards/*` auth proxy | Grafana 标准账号密码登录 | 旧嵌入代理仅可显式启用 |
| Grafana 数据源升级 | 复用已有数据源 | 按名称更新并保留原 UID | 无需配置 |

## Grafana 13 数据源升级兼容性

如果升级后 Grafana 容器进入 `Restarting` 状态，docker logs 末尾显示：

```
Error: ✗ *provisioning.ProvisioningServiceImpl run error:
       Datasource provisioning error: data source not found
```

**根因**：旧数据卷中已经存在名为 `TeslaMate` 的数据源，但它的 UID 可能由旧版 Grafana 自动生成。provisioning 文件若又强制指定不同的 `uid: TeslaMate`，Grafana 13 会按这个新 UID 查找更新目标，找不到时便以 `data source not found` 终止启动。

修复版不再覆盖已有数据源的身份，而是按 `name: TeslaMate` 更新它并保留原 UID。[Grafana 官方 provisioning 文档](https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources)也将 `uid` 定义为可选字段；不指定时由 Grafana 生成，新安装和旧数据卷都可以正常启动。

### 修复步骤（不删除数据）

```bash
cd /opt/teslamate-cn
git pull
docker compose -f docker-compose.zh-CN.yml build --no-cache grafana
docker compose -f docker-compose.zh-CN.yml up -d --force-recreate grafana

# 验证
docker compose -f docker-compose.zh-CN.yml ps
docker compose -f docker-compose.zh-CN.yml logs --tail=100 grafana | grep -iE "provision|error|started|healthy"
```

不要执行 `DELETE FROM data_source`，也不要删除 `teslamate-grafana-data` 卷；这不是修复所必需的，还会删除数据源身份及其关联配置。

## 为什么默认保持兼容

很多旧用户把 TeslaMate 跑在内网或单用户场景，长期不会手动重新登录 Tesla 账号。如果升级后立刻把所有页面强制登录，老用户会在 token 失效或重启后突然被挡在门外，体验差。

因此本版本的设计原则是：

> **新增能力默认关闭，配置开关开启后再生效**。

需要严格鉴权时，按下文启用即可。

## 启用 TeslaMate 页面鉴权（推荐公网部署）

1. 在 `.env` 中新增：
   ```bash
   TESLAMATE_STRICT_AUTH=true
   EMBED_GRAFANA=false
   # 可选：将 TeslaMate 与 Grafana 的 API 一起保护
   # TESLAMATE_PROTECT_API=true
   ```
2. 重新 `docker compose pull && docker compose up -d`。
3. 之后所有非 `/sign_in`、`/health_check`、LiveView WebSocket 升级之外的页面都需要先在 TeslaMate 里登录。
4. Grafana 继续通过独立 HTTPS 域名使用自己的账号密码登录，不依赖 TeslaMate 的 4000 端口。

旧 `/dashboards/*` 嵌入代理仍保留为兼容功能，但默认关闭。只有同时显式覆盖 Grafana auth proxy 配置时，才可设置 `EMBED_GRAFANA=true`。

## 端口安全

Compose 默认把 TeslaMate 和 Grafana 分别绑定到 `127.0.0.1:4000` 与 `127.0.0.1:3000`。请让 HTTPS 反向代理访问这些本机端口，不要改为 `0.0.0.0` 或省略绑定地址。

## 备份与回滚

本次上游同步包含三项数据库迁移：

- 为历史 `NULL` VIN 写入可识别的兼容占位值，再增加非空约束；
- 新增可恢复导入所需的检查点和拒绝记录表；
- 扩大地理围栏与充电费用字段精度。

这些迁移不会删除车辆、行程、充电记录或现有 PostgreSQL 数据源，但旧代码与新 schema 不能视为完全等价。升级前务必记录提交并创建 PostgreSQL 自定义格式备份：

```bash
git status --short
git rev-parse HEAD | tee teslamate-before-update.commit

BACKUP="teslamate-before-update-$(date +%Y%m%d-%H%M%S).dump"
docker compose -f docker-compose.zh-CN.yml exec -T database \
  pg_dump -U teslamate -d teslamate -Fc > "$BACKUP"

test -s "$BACKUP"
```

使用 1Panel 外部 PostgreSQL 时，不要新增 Compose 数据库服务。把上面的备份命令改为对现有 PostgreSQL 容器执行：

```bash
BACKUP="teslamate-before-update-$(date +%Y%m%d-%H%M%S).dump"
docker exec <PostgreSQL容器名> \
  pg_dump -U teslamate -d teslamate -Fc > "$BACKUP"
test -s "$BACKUP"
```

代码更新只允许使用 `git pull --ff-only`。如果升级后需要回退，先停止 TeslaMate，检出 `teslamate-before-update.commit` 中记录的提交，并恢复对应的升级前数据库备份；不要只回退镜像后继续写入已经迁移的数据库。Grafana 数据卷应原样保留，不要执行 `docker compose down -v`、`docker volume rm` 或删除 `/var/lib/grafana`。

### 1Panel 外部 PostgreSQL 部署

服务器已有 `docker-compose.1panel.yml` 时应继续使用该文件，不要用仓库中的独立部署 Compose 覆盖它。确认其中没有新增 PostgreSQL 服务，`DATABASE_HOST=postgres`、`DATABASE_PORT=5432` 保持不变，两个 Web 端口仍只监听回环地址。

完成上面的备份后执行：

```bash
COMPOSE_FILE=docker-compose.1panel.yml

git fetch origin
git pull --ff-only origin main

docker compose -f "$COMPOSE_FILE" config
docker volume inspect teslamate-grafana-data >/dev/null

TESLAMATE_REVISION="$(git rev-parse HEAD)" \
  docker compose -f "$COMPOSE_FILE" build --no-cache teslamate grafana

docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate grafana
docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate teslamate
```

上述命令不会重建外部 PostgreSQL，也不会删除 Grafana 数据卷。启动后按“Grafana 13 数据源升级兼容性”一节检查日志，并确认 `/login` 不返回 `500`、未登录访问 `/` 会跳转到登录页。

## Docker 发布流水线

发布的 Docker 镜像名和 tag 规则未改变，只是 CI 中 step id 之前引用错了（`steps.docker_meta.outputs.tags`），所以从某个版本开始发布的镜像是缺失 `tags` 的，会出现 push 失败或者打不出 label。新版本修复了这个问题；如果你的 fork 也有同样的问题，请对照 `.github/actions/build/action.yml` 把 `docker_meta` 改成 `meta`。

## Grafana "No data"

先在 Grafana 的 **Connections → Data sources → TeslaMate** 中执行 **Save & test**，再检查数据库是否已有车辆记录。不要通过给升级中的 provisioning 文件强加 UID 来处理；这会使已有随机 UID 的数据卷在 Grafana 13 启动时发生冲突。

## 常见问题

**Q: 启用了 `TESLAMATE_STRICT_AUTH=true`，但 token 过期后我不想再次登录，怎么办？**
A: 不要启用这个开关。或者在 `ENCRYPTION_KEY` 不变的前提下重新跑 `/sign_in`，Tesla tokens 会被加密存储在数据库中，下次启动自动续期。`ENCRYPTION_KEY` 必须固定，否则数据库里的 token 都解不出来。

**Q: 启用 `EMBED_GRAFANA=true` 后嵌不进去？**
A: 这是兼容模式，必须另外显式配置 Grafana auth proxy。默认镜像使用标准账号密码登录，不会自动启用代理认证。

**Q: 之前仪表盘直接打开 `:3000`，现在如何访问？**
A: 服务器本机可使用 `http://127.0.0.1:3000/login`；远程使用反向代理后的 HTTPS 域名。
