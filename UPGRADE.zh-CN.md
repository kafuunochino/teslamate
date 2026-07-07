# 升级迁移指南：从 1.x 升级到当前版本

本指南帮助从之前的 TeslaMate 版本升级而来的用户理解默认行为变化和如何回退/启用新增功能。所有改动默认与历史版本**行为完全一致**，新行为需要显式设置环境变量。

## 概览

| 行为 | 之前 | 默认（升级后） | 启用新版 |
|---|---|---|---|
| TeslaMate 页面是否强制登录才能访问设置/地理围栏 | 否 | 否（保持兼容） | `TESLAMATE_STRICT_AUTH=true` |
| `POST/GET /api/car/*/logging/{resume,suspend}` 是否检查登录态 | 否 | 否 | `TESLAMATE_PROTECT_API=true` |
| Grafana 端口 `3000` 是否对外暴露 | 是（docker-compose） | 否（仅容器内 `expose`） | 在 `docker-compose.zh-CN.yml` 中手动加 `ports: "3000:3000"` |
| Grafana 是否需要走 `/dashboards/*` 反向代理 | 无 | 是（导航自动使用） | `EMBED_GRAFANA=true`（默认） |
| Grafana "No data" 的根因 | provisioning 文件缺 `uid` | 修复后正常 | 无需配置 |

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

历史上 `grafana/datasource.yml` 没有 `uid`，但 `grafana/dashboards/**/*.json` 中的 panel 都通过 `uid: "TeslaMate"` 引用 datasource，所以 dashboard 一直报 "No data" 或仅显示部分数据。本版本补上了 `uid: TeslaMate`，重启 `grafana` 容器后即可。

## 常见问题

**Q: 启用了 `TESLAMATE_STRICT_AUTH=true`，但 token 过期后我不想再次登录，怎么办？**
A: 不要启用这个开关。或者在 `ENCRYPTION_KEY` 不变的前提下重新跑 `/sign_in`，Tesla tokens 会被加密存储在数据库中，下次启动自动续期。`ENCRYPTION_KEY` 必须固定，否则数据库里的 token 都解不出来。

**Q: 启用 `EMBED_GRAFANA=true` 后嵌不进去？**
A: 检查 Grafana 是否真的启用了 auth_proxy（`GF_AUTH_PROXY_ENABLED=true`）。如果 Grafana 镜像来自外部（比如 `teslamate/grafana` 标签），需要确认其默认配置包含 proxy。

**Q: 之前仪表盘直接打开 `:3000`，现在被反代了怎么办？**
A: 在 `docker-compose.zh-CN.yml` 里加上 `ports: ["3000:3000"]` 显式启用旧路径，详见上文。
