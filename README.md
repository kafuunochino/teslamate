# TeslaMate CN 统一车辆数据平台

[升级迁移指南](UPGRADE.zh-CN.md) · [权限与安全模型](PLATFORM_SECURITY.zh-CN.md) · [English documentation](README.en.md)

本分支保留 TeslaMate 成熟的车辆采集器、MQTT 和 PostgreSQL 遥测数据模型，重新构建了面向多人使用的 Phoenix LiveView 前端。车辆首页、行程轨迹、电池、充电、分析、用户与车辆权限现在由同一个应用提供；Docker 只向宿主机发布 `127.0.0.1:3000`，不再需要把 4000 与 Grafana 分开暴露。

现有 `cars`、`drives`、`positions`、`charging_processes`、地址、地理围栏和 Tesla 令牌都会原样复用。升级只在 `private` schema 中增加平台账号、会话、车辆授权、一次性认领码和审计表，不会重新初始化遥测数据库。

> [!CAUTION]
> 平台保存车辆精确位置、轨迹和加密的 Tesla API 令牌。3000 必须继续绑定 `127.0.0.1`，公网只通过 HTTPS 反向代理访问。不要把 PostgreSQL、MQTT 或旧 Grafana 端口直接开放到公网。

## 功能

- 首页：车辆状态、当前电量、额定续航、累计里程、海拔、温度、软件版本、当前位置、近期行程与充电。
- 行程轨迹：时间范围、路线地图、里程、时长、速度、海拔变化、常去地点和授权校验后的 GPX 导出。
- 电池：归一化满电额定续航趋势、估算变化、充电累计和最近胎压。页面明确区分统计估算与官方 BMS 检测。
- 充电：会话、电网取电、充入电量、时长、费用、平均电价和常用充电地点。
- 分析：能效、短途/夜间出行、充电习惯、月度里程和可解释建议；不冒充驾驶安全评级或车辆诊断。
- 多用户：公开注册可配置；新用户默认没有任何车辆权限。
- 权限：管理员查看全部车辆并管理账号；普通用户只能查询明确绑定的车辆。
- 安全绑定：管理员生成一次性、限时认领码。数据库只保存 SHA-256 哈希，原文只显示一次；VIN、车辆名称和车牌不能用于认领。
- 响应式界面：固定左侧分类导航，手机和平板使用抽屉菜单，表格自动转为移动布局。

## 运行架构

| 组件                     | 默认行为                                                            |
| ------------------------ | ------------------------------------------------------------------- |
| `teslamate`              | 采集器、统一前后端、登录与权限；容器/宿主机端口均为 3000            |
| PostgreSQL               | 1Panel 部署继续连接已有 `postgres:5432`，Compose 不创建或替换数据库 |
| `mosquitto`              | 仅容器网络使用，不发布宿主机端口                                    |
| `grafana`                | 只保留为 `legacy-grafana` 兼容 profile，默认不启动且不发布端口      |
| `teslamate-grafana-data` | 原名保留，不删除、不重新初始化                                      |

平台登录账号与 Tesla 采集凭据是两套独立身份。普通用户永远不会获得 Tesla access/refresh token；只有管理员能进入“Tesla 连接”、系统设置、地理围栏和数据导入页面。

## 1Panel 现有部署升级

不要直接用一条 `git pull && docker compose up` 跳过备份和端口切换。现有服务器通常有一个未纳入 Git 的 `docker-compose.1panel.yml`，而本版本开始由仓库维护该文件；升级前必须先备份旧文件。完整、可复制的无损步骤见 [UPGRADE.zh-CN.md](UPGRADE.zh-CN.md)。

关键保证：

- `DATABASE_HOST=postgres`、`DATABASE_PORT=5432` 可保持不变；
- 默认外部网络为 `1panel-network`，不同名称可通过 `PANEL_NETWORK` 指定；
- 只停止并移除旧 Grafana 容器以释放宿主机 3000，绝不删除它的数据卷；
- 新容器启动时自动执行增量迁移；
- Nginx 上游仍是 `http://127.0.0.1:3000`，无需改公网域名；
- 旧 TeslaMate 的 4000 映射会随容器重建消失。

严禁执行：

```bash
docker compose down -v
docker volume rm teslamate-grafana-data
rm -rf /var/lib/grafana
```

## 新安装（仓库自带 PostgreSQL）

1. 准备环境变量：

   ```bash
   cp .env.example .env
   chmod 600 .env
   openssl rand -base64 64
   openssl rand -base64 64
   openssl rand -base64 32
   ```

   把三次输出分别写入 `.env` 的 `ENCRYPTION_KEY`、`SECRET_KEY_BASE` 和 `SIGNING_SALT`，同时设置强 `DATABASE_PASS`。这些值部署后必须永久保存，不要写入 Git。

2. 构建并启动：

   ```bash
   TESLAMATE_REVISION="$(git rev-parse HEAD)" \
     docker compose -f docker-compose.zh-CN.yml up -d --build teslamate mosquitto database
   ```

3. 创建或重置首个平台管理员。命令不会把密码明文写进 shell 历史：

   ```bash
   read -r -p '管理员邮箱: ' ADMIN_EMAIL
   read -r -s -p '管理员新密码（至少 12 位）: ' ADMIN_PASSWORD
   printf '\n'

   docker compose -f docker-compose.zh-CN.yml exec \
     -e TESLAMATE_ADMIN_EMAIL="$ADMIN_EMAIL" \
     -e TESLAMATE_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
     -e TESLAMATE_ADMIN_NAME="平台管理员" \
     teslamate bin/teslamate eval 'TeslaMate.Release.create_admin_from_env()'

   unset ADMIN_PASSWORD
   ```

4. 通过本机 `http://127.0.0.1:3000/sign_in` 或 HTTPS 域名登录。管理员随后在“系统管理 → Tesla 连接”中配置采集器凭据。

## 用户注册与车辆绑定

1. `TESLAMATE_ALLOW_SIGN_UP=true` 时，访客可在 `/register` 创建普通账号。
2. 新账号即使知道 VIN，也看不到任何车辆和轨迹。
3. 管理员进入“用户与权限”，选择具体车辆并生成 1、8、24 或 72 小时认领码，也可直接授权。
4. 管理员通过可信渠道把原文发送给对应用户。认领码是短期凭据，不应发到公开群聊。
5. 用户在“车辆中心”兑换后，只获得该车辆的只读数据权限。
6. 用户解除绑定只删除授权关系，不删除车辆、行程、位置、充电或 PostgreSQL 数据。

公网注册暂不包含邮件验证或密码找回邮件。无需开放注册时请设置 `TESLAMATE_ALLOW_SIGN_UP=false`，管理员仍可保留已有账号和权限。

## HTTPS 反向代理

1Panel/Nginx 继续代理到：

```text
http://127.0.0.1:3000
```

至少转发 `Host`、`X-Forwarded-Proto`、`X-Forwarded-For`，并允许 WebSocket Upgrade。生产 `.env` 建议设置：

```dotenv
VIRTUAL_HOST=car.example.com
CHECK_ORIGIN=https://car.example.com
TESLAMATE_TRUSTED_PROXIES=反向代理容器或网段
TESLAMATE_API_ORIGIN_CHECK=true
```

浏览器会话 Cookie 在生产镜像中强制 `Secure`、`HttpOnly` 和 `SameSite=Strict`，因此实际登录应使用 HTTPS。反向代理应负责 HTTP 到 HTTPS 跳转及 HSTS；确认域名只提供 HTTPS 后再启用 HSTS。

## 常用命令

```bash
COMPOSE_FILE=docker-compose.1panel.yml

docker compose -f "$COMPOSE_FILE" config
docker compose -f "$COMPOSE_FILE" ps
docker compose -f "$COMPOSE_FILE" logs --tail=200 teslamate
docker compose -f "$COMPOSE_FILE" restart teslamate
curl -I http://127.0.0.1:3000/sign_in
```

更新只重新构建统一服务，不需要启动 Grafana：

```bash
TESLAMATE_REVISION="$(git rev-parse HEAD)" \
  docker compose -f docker-compose.1panel.yml build --no-cache teslamate
docker compose -f docker-compose.1panel.yml up -d --force-recreate teslamate mosquitto
```

## 旧 Grafana 数据

默认运行不再使用 Grafana，但 `teslamate-grafana-data` 会原样保留。需要迁移期查看或导出旧仪表板时，可临时在容器网络内启动兼容 profile；它不会发布宿主机端口：

```bash
docker compose -f docker-compose.1panel.yml --profile legacy-grafana up -d grafana
docker compose -f docker-compose.1panel.yml --profile legacy-grafana logs --tail=100 grafana
```

已有 Grafana 数据卷的管理员密码不会因环境变量改变。需要重置时：

```bash
docker compose -f docker-compose.1panel.yml --profile legacy-grafana exec grafana \
  grafana cli admin reset-admin-password '新的强密码'
```

Grafana 13 当前镜像仍支持上述 `grafana cli admin reset-admin-password` 路径。完成导出后只移除容器，保留卷：

```bash
docker compose -f docker-compose.1panel.yml --profile legacy-grafana stop grafana
docker compose -f docker-compose.1panel.yml --profile legacy-grafana rm -f grafana
```

## 数据与隐私说明

- 管理员权限不等于 Tesla 账号密码；采集器使用全局、加密保存的 Tesla token。
- 所有车辆数据查询都先按当前平台用户解析可访问车辆；行程详情和 GPX 同样执行该校验。
- 密码使用 PBKDF2-HMAC-SHA256（每用户随机盐，600,000 次迭代），会话和认领码仅存哈希。
- 角色或账号状态变化会撤销该用户全部会话；最后一个有效管理员不能被停用或降级。
- 地图瓦片来自 OpenStreetMap，查看地图会向瓦片提供方暴露近似地图区域。需要完全离线隐私时，应在后续版本接入自托管瓦片服务。

更完整的威胁边界、权限矩阵与当前限制见 [PLATFORM_SECURITY.zh-CN.md](PLATFORM_SECURITY.zh-CN.md)。
