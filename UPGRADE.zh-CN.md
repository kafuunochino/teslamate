# 升级迁移指南：从 1.x 升级到当前版本

本指南帮助从之前的 TeslaMate 版本升级而来的用户理解默认行为变化和如何回退/启用新增功能。所有改动默认与历史版本**行为完全一致**，新行为需要显式设置环境变量。

## 概览

| 行为 | 之前 | 默认（升级后） | 启用新版 |
|---|---|---|---|
| TeslaMate 页面是否强制登录才能访问设置/地理围栏 | 否 | 否（保持兼容） | `TESLAMATE_STRICT_AUTH=true` |
| `POST/GET /api/car/*/logging/{resume,suspend}` 是否检查登录态 | 否 | 否 | `TESLAMATE_PROTECT_API=true` |
| Grafana 端口 `3000` 是否对外暴露 | 是（docker-compose） | 否（仅容器内 `expose`） | 在 `docker-compose.zh-CN.yml` 中手动加 `ports: "3000:3000"` |
| Grafana 是否需要走 `/dashboards/*` 反向代理 | 无 | 是（导航自动使用） | `EMBED_GRAFANA=true`（默认） |
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
docker compose -f docker-compose.zh-CN.yml down
docker compose -f docker-compose.zh-CN.yml build --no-cache grafana
docker compose -f docker-compose.zh-CN.yml up -d --build

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

## 启用统一鉴权（推荐公网部署）

1. 在 `.env` 中新增：
   ```bash
   TESLAMATE_STRICT_AUTH=true
   EMBED_GRAFANA=true
   # 可选：将 TeslaMate 与 Grafana 的 API 一起保护
   # TESLAMATE_PROTECT_API=true
   ```
2. 重新 `docker compose pull && docker compose up -d`。
3. 之后所有非 `/sign_in`、`/health_check`、LiveView WebSocket 升级之外的页面都需要先在 TeslaMate 里登录。
4. 顶部导航栏"Dashboards"下拉会跳转到 `/dashboards/d/<uid>`（嵌入的 Grafana），而不是新窗口打开外部地址。

## 还原旧行为（仅当你不想改变现状）

- 把上述 `.env` 三个开关全部留空或不设置。
- 如果你**确实**还需要直接访问 `:3000`，在 `docker-compose.zh-CN.yml` 的 `grafana` 服务下加：
  ```yaml
  ports:
    - "3000:3000"
  ```

## 备份与回滚

升级前务必：

```bash
docker compose exec database pg_dump -U teslamate teslamate > backup_$(date +%F).sql
```

如果新版本无法启动，可以直接 `git checkout <旧 tag>` 并 `docker compose up -d`，因为数据库 schema 没有改动，升级和回滚都安全。

## Docker 发布流水线

发布的 Docker 镜像名和 tag 规则未改变，只是 CI 中 step id 之前引用错了（`steps.docker_meta.outputs.tags`），所以从某个版本开始发布的镜像是缺失 `tags` 的，会出现 push 失败或者打不出 label。新版本修复了这个问题；如果你的 fork 也有同样的问题，请对照 `.github/actions/build/action.yml` 把 `docker_meta` 改成 `meta`。

## Grafana "No data"

先在 Grafana 的 **Connections → Data sources → TeslaMate** 中执行 **Save & test**，再检查数据库是否已有车辆记录。不要通过给升级中的 provisioning 文件强加 UID 来处理；这会使已有随机 UID 的数据卷在 Grafana 13 启动时发生冲突。

## 常见问题

**Q: 启用了 `TESLAMATE_STRICT_AUTH=true`，但 token 过期后我不想再次登录，怎么办？**
A: 不要启用这个开关。或者在 `ENCRYPTION_KEY` 不变的前提下重新跑 `/sign_in`，Tesla tokens 会被加密存储在数据库中，下次启动自动续期。`ENCRYPTION_KEY` 必须固定，否则数据库里的 token 都解不出来。

**Q: 启用 `EMBED_GRAFANA=true` 后嵌不进去？**
A: 检查 Grafana 是否真的启用了 auth_proxy（`GF_AUTH_PROXY_ENABLED=true`）。如果 Grafana 镜像来自外部（比如 `teslamate/grafana` 标签），需要确认其默认配置包含 proxy。

**Q: 之前仪表盘直接打开 `:3000`，现在被反代了怎么办？**
A: 在 `docker-compose.zh-CN.yml` 里加上 `ports: ["3000:3000"]` 显式启用旧路径，详见上文。
