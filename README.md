# TeslaMate 简体中文使用说明

[English documentation](README.en.md) · [Windows / Linux / macOS 原生安装（不使用 Docker）](NATIVE_INSTALL.zh-CN.md) · [安全审计](SECURITY_AUDIT.zh-CN.md)

本项目保持 TeslaMate 的车辆采集、MQTT 与 PostgreSQL 核心架构不变，完成了网页界面、表单校验信息和内置 Grafana 仪表盘的简体中文本地化，并以独立迁移和只读查询增加中国区仪表盘功能。网页应用和 Grafana 默认使用简体中文。

推荐直接阅读 [Windows / Linux / macOS 原生安装说明](NATIVE_INSTALL.zh-CN.md)，无需使用 Docker。本项目还包含 25 个经过安全清理的中国区增强仪表盘、默认高德地图、GCJ-02 坐标纠偏、安全旁路分时电价和 Grafana 只读数据库账户。Docker 安装方式作为备选保留在本文后续章节。

> [!CAUTION]
> TeslaMate 会保存 Tesla API 令牌和车辆轨迹。请只在可信设备上部署，设置高强度密钥与密码。Compose 默认把 3000、4000 端口绑定到 `127.0.0.1`，远程访问请使用 VPN、Tailscale、Cloudflare Tunnel 或 HTTPS 反向代理，不要改成对公网监听。

## 一、准备工作

- 一台可长期运行的 64 位设备；建议至少 2 GB 内存。
- Docker 与 Docker Compose。
- 可访问 Tesla 服务和 Docker 镜像仓库的网络。
- Tesla API 的访问令牌（Access Token）和刷新令牌（Refresh Token）。

## 二、首次安装

1. 进入项目目录，复制环境变量示例文件：

   ```bash
   cp .env.zh-CN.example .env
   ```

2. 编辑 `.env`，务必替换以下两项：
   - `ENCRYPTION_KEY`：用于加密 Tesla API 令牌。建议使用密码管理器生成至少 32 位的随机字符串；部署后请妥善保存，不能随意更换。
   - `DATABASE_PASS`：PostgreSQL 数据库密码，建议使用独立的高强度随机密码。

3. 中国大陆账户的 API 与流式服务地址会根据令牌区域自动选择，通常无需手工设置；只有排查特殊网络问题时才使用 Compose 文件中的显式覆盖项。

4. 构建并启动服务。构建时传入当前 Git 提交号，供“设置 → 检查项目更新”准确比较差异：

   Linux / macOS：

   ```bash
   TESLAMATE_REVISION="$(git rev-parse HEAD)" docker compose -f docker-compose.zh-CN.yml up -d --build
   ```

   Windows PowerShell：

   ```powershell
   $env:TESLAMATE_REVISION = git rev-parse HEAD
   docker compose -f docker-compose.zh-CN.yml up -d --build
   ```

5. 查看启动状态：

   ```bash
   docker compose -f docker-compose.zh-CN.yml ps
   docker compose -f docker-compose.zh-CN.yml logs -f teslamate
   ```

   日志出现服务已启动的信息后，按 `Ctrl+C` 退出日志查看即可，不会停止容器。

## 三、登录与日常使用

1. 在服务器本机打开 `http://127.0.0.1:4000`，远程访问请使用已配置的安全反向代理地址。
2. 在登录页填写 Tesla API 的访问令牌和刷新令牌，然后登录。
3. 首页用于查看车辆状态、续航、充电、温度与里程。顶部的“地理围栏”可配置常用地点和充电价格，“设置”可调整单位、休眠条件、主题与地址语言。
4. 在服务器本机打开 `http://127.0.0.1:3000/login`，或打开反向代理后的 HTTPS 域名登录 Grafana。默认禁止匿名访问和用户自行注册，不依赖 TeslaMate 的 4000 端口认证。
5. 现有数据卷会保留原有 Grafana 用户和密码；首次部署使用 Grafana 创建的管理员账号，登录后请立即设置强密码。
6. 如果网页没有自动显示中文，可访问 TeslaMate 地址并添加 `/?locale=zh_Hans`，随后在“设置 → 语言 → 网页应用”中选择简体中文。

忘记现有 Grafana 管理员密码时，可在不删除数据卷的情况下重置：

```bash
docker compose -f docker-compose.zh-CN.yml exec grafana \
  grafana cli admin reset-admin-password '新的强密码'
```

`GF_SECURITY_ADMIN_PASSWORD` 只在首次创建管理员时生效，不能替代上述已有数据卷的密码重置命令。

Tesla 官方令牌获取说明会随 Tesla API 政策变化，请以 [TeslaMate 官方常见问题](https://docs.teslamate.org/docs/faq#how-to-generate-your-own-tokens) 为准。不要把令牌发送给他人或写入 Git 仓库。

## 四、常用管理命令

```bash
# 查看全部服务状态
docker compose -f docker-compose.zh-CN.yml ps

# 查看 TeslaMate 日志
docker compose -f docker-compose.zh-CN.yml logs -f teslamate

# 重启服务
docker compose -f docker-compose.zh-CN.yml restart

# 停止服务（保留数据库和 Grafana 数据）
docker compose -f docker-compose.zh-CN.yml down

# 重新构建并启动当前代码（Linux / macOS）
TESLAMATE_REVISION="$(git rev-parse HEAD)" docker compose -f docker-compose.zh-CN.yml up -d --build
```

不要使用 `docker compose down -v`，其中的 `-v` 会删除数据库和 Grafana 数据卷。

## 五、更新

先记录旧版本并备份数据库，再以 fast-forward 方式拉取代码并重新构建：

```bash
git status --short
git rev-parse HEAD | tee teslamate-before-update.commit

BACKUP="teslamate-before-update-$(date +%Y%m%d-%H%M%S).dump"
docker compose -f docker-compose.zh-CN.yml exec -T database \
  pg_dump -U teslamate -d teslamate -Fc > "$BACKUP"
test -s "$BACKUP"

git fetch origin
git pull --ff-only origin main
TESLAMATE_REVISION="$(git rev-parse HEAD)" docker compose -f docker-compose.zh-CN.yml up -d --build
```

如果 `git status --short` 有输出，请先保存服务器本地修改，不要直接覆盖。当前版本包含数据库迁移；迁移不会删除车辆、行程或充电数据，但回退到旧代码时应同时恢复升级前的数据库备份。Windows PowerShell 在重新构建前先执行 `$env:TESLAMATE_REVISION = git rev-parse HEAD`。更新完成后检查 `ps` 和 TeslaMate 日志。恢复数据库前请停止 TeslaMate，并确认备份文件完整可读。

## 六、数据导入

Compose 文件把项目内的 `import` 目录挂载到容器的 `/opt/app/import`。将 TeslaFi 等受支持的导出文件放入 `import` 目录，然后打开 TeslaMate 的导入页面。导入前建议先备份数据库；大量历史数据的导入可能需要较长时间。

## 七、常见问题

- 网页打不开：确认 `docker compose ... ps` 中 `teslamate` 为运行状态，并检查 4000 端口是否被占用或被防火墙拦截。
- Grafana 没有数据：先确认 TeslaMate 已成功连接车辆并产生记录，再检查 `grafana` 和 `database` 服务日志。
- Grafana 登录页返回 500 且日志包含 `org.notFound`：重新构建 Grafana，确认容器中匿名认证和 auth proxy 均为 `false`，不要删除 `teslamate-grafana-data`。
- Grafana 启动时提示数据源配置导入失败：请拉取最新代码并仅重新构建服务，不要删除 `teslamate-grafana-data` 数据卷；修复版会按已有数据源名称更新配置并保留原 UID。
- 重启后需要重新登录：确认 `.env` 中设置了固定的 `ENCRYPTION_KEY`，且启动时使用了同一个 `.env`。
- 数据库连接失败：确认 `.env` 中的 `DATABASE_PASS` 没有被修改，并且 Compose 中数据库与其他服务使用的是同一个值。
- 中国大陆车辆无法连接：确认已启用 Compose 文件中的中国区 API 与流式服务地址，并检查网络连通性。
- 汉化未生效：本项目需要从源码构建；直接使用官方 `teslamate/teslamate:latest` 或 `teslamate/grafana:latest` 镜像不会包含本项目的汉化内容。

更多高级配置、反向代理、Home Assistant、MQTT 与数据修复说明，请参考 [TeslaMate 官方文档](https://docs.teslamate.org/)。
