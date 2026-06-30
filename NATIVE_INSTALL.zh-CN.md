# Windows / Linux / macOS 原生安装说明

本说明用于直接在操作系统上运行 TeslaMate、PostgreSQL 和 Grafana，不使用 Docker。TeslaMate 保持 PostgreSQL 后端；SQLite 无法兼容现有迁移、地理围栏和 Grafana 查询。

## 1. 安全原则

- 默认只监听 `127.0.0.1`。需要局域网访问时，再把 `HTTP_BINDING_ADDRESS` 改为局域网接口或 `0.0.0.0`，把 `VIRTUAL_HOST` 设为实际主机名或局域网 IP，并把 `CHECK_ORIGIN` 设为实际访问来源（例如 `http://192.168.1.20:4000`）；同时用防火墙限制来源。
- 不要把 3000、4000、5432、1883 端口直接开放到公网。远程访问使用 VPN、Tailscale、WireGuard 或带 HTTPS 与身份认证的反向代理。
- TeslaMate 与 Grafana 使用不同的数据库账户。Grafana 必须使用本文创建的只读账户，不能使用 TeslaMate 的写入账户。
- `.env.native` 含加密密钥和数据库密码，已被 `.gitignore` 排除；不要发送、截图或提交它。
- 不执行 `curl | sh`、`wget | bash` 或来源不明的一键脚本。

## 2. 版本要求

本仓库当前构建基线：

| 组件        | 建议版本                | 用途                     |
| ----------- | ----------------------- | ------------------------ |
| Erlang/OTP  | 28                      | Elixir 运行时            |
| Elixir      | 1.19.5（OTP 28）        | TeslaMate 主程序         |
| Node.js     | 22 LTS                  | 构建网页资源             |
| PostgreSQL  | 18                      | 数据库与仪表盘查询       |
| Grafana OSS | 13.0.1 或同系列安全更新 | 仪表盘                   |
| Mosquitto   | 2.x，可选               | MQTT/Home Assistant 集成 |
| Git         | 当前受支持版本          | 获取与更新源码           |

只从各项目官方网站或操作系统可信软件源安装：

- [Elixir](https://elixir-lang.org/install.html) / [Erlang](https://www.erlang.org/downloads)
- [Node.js](https://nodejs.org/en/download)
- [PostgreSQL](https://www.postgresql.org/download/)
- [Grafana](https://grafana.com/docs/grafana/latest/setup-grafana/installation/)
- [Mosquitto](https://mosquitto.org/download/)

安装后检查：

```text
elixir --version
mix --version
node --version
npm --version
psql --version
grafana server -v
```

## 3. 各系统安装依赖

### Windows 10/11

1. 安装 64 位 Erlang/OTP 28，然后安装匹配 OTP 28 的 Elixir 1.19.5。
2. 安装 Node.js 22 LTS、Git、PostgreSQL 18 和 Grafana OSS。
3. 安装程序询问 PostgreSQL 超级用户密码时，设置一个独立强密码并妥善保存。
4. 将 Elixir、Erlang、Node、PostgreSQL `bin` 和 Grafana `bin` 加入 `PATH`，重新打开 PowerShell 后运行版本检查。
5. 需要 MQTT 时安装 Mosquitto；否则稍后保持 `DISABLE_MQTT=true`。

### Linux

以 Ubuntu/Debian 为例：

1. 从 Elixir 官方列出的受支持仓库或版本管理器安装 OTP 28 与 Elixir 1.19.5；发行版自带版本过旧时不要强行使用。
2. 从 Node.js 官方渠道安装 Node 22 LTS。
3. 从 PostgreSQL 官方 PGDG 仓库安装 PostgreSQL 18，并启动 PostgreSQL 服务。
4. 从 Grafana 官方 APT/RPM 仓库安装 Grafana OSS 13，并暂时不要开放公网端口。
5. 可选安装 Mosquitto 2；不使用 MQTT 时无需安装。

不同发行版的服务命令不同。安装完成后，通常可用以下命令检查服务：

```bash
systemctl status postgresql
systemctl status grafana-server
systemctl status mosquitto   # 仅安装 MQTT 时
```

### macOS

使用 Homebrew 的示例：

```bash
brew install git erlang elixir node@22 postgresql@18 grafana
brew services start postgresql@18

# 需要 MQTT/Home Assistant 时再安装：
brew install mosquitto
brew services start mosquitto
```

Homebrew 升级后可能安装比表中更新的兼容版本。若 `mix deps.compile` 报 OTP/Elixir 不匹配，请按上方基线安装匹配版本。

## 4. 创建 PostgreSQL 数据库

以下命令会交互式询问密码，避免把密码写入终端历史。`postgres` 超级用户名称可能因系统安装方式不同而变化。

```bash
createuser -U postgres --pwprompt teslamate
createdb -U postgres -O teslamate teslamate
```

确认连接正常：

```bash
psql -U teslamate -h 127.0.0.1 -d teslamate -c "SELECT current_database(), current_user;"
```

## 5. 获取源码并生成配置

```bash
git clone https://github.com/kafuunochino/teslamate.git
cd teslamate
```

### Windows PowerShell

```powershell
Copy-Item .env.native.example .env.native

# 每执行一次生成一个 64 位十六进制随机值；分别填入
# ENCRYPTION_KEY、SECRET_KEY_BASE 和 SIGNING_SALT。
$bytes = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($bytes)
[BitConverter]::ToString($bytes).Replace('-', '').ToLower()
$rng.Dispose()

notepad .env.native
```

把数据库密码填入 `DATABASE_PASS`，替换全部 `CHANGE_ME`。默认只监听本机并关闭 MQTT。

### Linux / macOS

```bash
cp .env.native.example .env.native
openssl rand -hex 32   # 分别为 ENCRYPTION_KEY、SECRET_KEY_BASE、SIGNING_SALT 生成值
chmod 600 .env.native
${EDITOR:-vi} .env.native
```

## 6. 构建并启动 TeslaMate

### Windows PowerShell

```powershell
powershell -ExecutionPolicy Bypass -File scripts/native/Setup-Native.ps1
powershell -ExecutionPolicy Bypass -File scripts/native/Start-Native.ps1
```

### Linux / macOS

```bash
sh scripts/native/setup.sh
sh scripts/native/start.sh
```

首次构建会下载 Elixir 与 Node 依赖并执行数据库迁移。看到 Phoenix 启动信息后访问 <http://127.0.0.1:4000>。

中国区 Tesla API 与流式服务会根据令牌区域自动选择，一般不需要手工设置 `TESLA_API_HOST` 或 `TESLA_WSS_HOST`。地址反查访问困难时，可在 `.env.native` 中设置可信的本地 HTTP 代理 `NOMINATIM_PROXY`。

## 7. 配置 Grafana 只读账户

先保持 TeslaMate 至少成功执行过一次迁移，然后以 PostgreSQL 管理员运行：

```bash
psql -U postgres -d teslamate -f priv/sql/create_grafana_readonly_role.sql
```

脚本会用隐藏输入提示设置 `teslamate_grafana` 的独立密码，密码不会进入命令历史或进程参数。该脚本只授予 `public` schema 的查询权限，不授予保存加密 Tesla 令牌的 `private` schema，也不授予写入权限。

为 Grafana 进程设置：

```text
GRAFANA_DATABASE_HOST=127.0.0.1
GRAFANA_DATABASE_PORT=5432
GRAFANA_DATABASE_NAME=teslamate
GRAFANA_DATABASE_USER=teslamate_grafana
GRAFANA_DATABASE_PASS=上一步的只读账户密码
GRAFANA_DATABASE_SSL_MODE=disable
TESLAMATE_DASHBOARDS_PATH=项目绝对路径/grafana/dashboards
TESLAMATE_INTERNAL_DASHBOARDS_PATH=项目绝对路径/grafana/dashboards/internal
TESLAMATE_REPORT_DASHBOARDS_PATH=项目绝对路径/grafana/dashboards/reports
GF_USERS_DEFAULT_LANGUAGE=zh-Hans
GF_AUTH_ANONYMOUS_ENABLED=false
GF_USERS_ALLOW_SIGN_UP=false
```

把以下两个文件复制到 Grafana provisioning 目录：

- `grafana/datasource-native.yml` → `provisioning/datasources/teslamate.yml`
- `grafana/dashboards-native.yml` → `provisioning/dashboards/teslamate.yml`

常见 provisioning 路径：

| 系统                         | 路径                                     |
| ---------------------------- | ---------------------------------------- |
| Windows ZIP/安装版           | Grafana 安装目录下的 `conf/provisioning` |
| Linux 软件包                 | `/etc/grafana/provisioning`              |
| macOS Apple Silicon Homebrew | `/opt/homebrew/etc/grafana/provisioning` |
| macOS Intel Homebrew         | `/usr/local/etc/grafana/provisioning`    |

确保启动 Grafana 的服务或终端进程能读取上述环境变量，然后重启 Grafana。访问 <http://127.0.0.1:3000>，首次登录后立即更改管理员密码。

## 8. 中国大陆地图说明

- 增强仪表盘默认使用高德地图。
- TeslaMate 保存的原始 WGS-84 坐标只在查询展示时转换为 GCJ-02，数据库原始轨迹不会被修改。
- OpenStreetMap 选项保持原始 WGS-84 坐标。
- 地图瓦片服务会收到网络地址、视野范围和缩放级别；不希望外部请求时不要打开地图仪表盘。

## 9. 安全配置分时电价（可选）

分时电价使用独立的 `tm_tou_rates` 和 `tm_charging_costs` 表，不覆盖 TeslaMate 原生 `charging_processes.cost`。没有安装第三方 Grafana 写入插件。

每个时段执行一次配置脚本。以下示例设置全局交流慢充谷价（北京时间 22:00 至次日 08:00）：

Linux / macOS：

```bash
psql -U teslamate -h 127.0.0.1 -d teslamate \
  -v geofence_id='' \
  -v hour_start=22 \
  -v hour_end=8 \
  -v rate=0.30 \
  -v label='谷' \
  -v apply_to_dc=false \
  -f priv/sql/configure_tou_rate.sql
```

Windows PowerShell：

```powershell
psql -U teslamate -h 127.0.0.1 -d teslamate `
  -v "geofence_id=" `
  -v "hour_start=22" `
  -v "hour_end=8" `
  -v "rate=0.30" `
  -v "label=谷" `
  -v "apply_to_dc=false" `
  -f priv/sql/configure_tou_rate.sql
```

继续分别写入峰、平等全部时段。时段必须完整覆盖一天；如果存在缺口，系统会返回空值并回退原始费用，不会把缺失时段错误地按零元计算。

配置完成后重算历史充电：

```bash
psql -U teslamate -h 127.0.0.1 -d teslamate -c "SELECT * FROM tm_backfill_tou();"
```

检查配置和旁路结果：

```bash
psql -U teslamate -h 127.0.0.1 -d teslamate -c \
  "SELECT id, geofence_id, hour_start, hour_end, rate, label, apply_to_dc FROM tm_tou_rates ORDER BY hour_start;"

psql -U teslamate -h 127.0.0.1 -d teslamate -c \
  "SELECT * FROM tm_charging_costs ORDER BY charging_process_id DESC LIMIT 20;"
```

电价政策会变化，本项目不内置城市价格。请以当地供电机构最新公布的居民充电电价为准。

## 10. 后台长期运行

- Windows：使用“任务计划程序”以专用本地账户在登录或开机时运行 `scripts/native/Start-Native.ps1`，不要勾选最高管理员权限，工作目录设为项目目录。
- Linux：创建普通用户运行 TeslaMate，并用 systemd `EnvironmentFile=` 指向权限为 `600` 的 `.env.native`；不要使用 root 用户。
- macOS：可创建用户级 LaunchAgent 调用 `scripts/native/start.sh`；不要把密钥写进 plist，脚本会读取权限受限的 `.env.native`。

Grafana 和 PostgreSQL 使用各自系统服务。TeslaMate 更新前先备份数据库：

```bash
pg_dump -U teslamate -h 127.0.0.1 -d teslamate -Fc -f teslamate-backup.dump
git pull --ff-only
sh scripts/native/setup.sh                 # Windows 使用 Setup-Native.ps1
```

## 11. 验证与排错

```bash
node scripts/validate-china-dashboards.mjs
psql -U teslamate_grafana -h 127.0.0.1 -d teslamate -c "SELECT count(*) FROM cars;"
```

- `function tm_lat_for_map does not exist`：TeslaMate 数据库迁移没有完成，重新运行原生 setup 脚本。
- Grafana 报权限不足：确认只读角色脚本是在 TeslaMate 迁移之后执行；新增表后可安全重跑脚本。
- 地址为空：检查 OpenStreetMap 访问或配置 `NOMINATIM_PROXY`。
- 中国区 API 连接失败：先确认令牌属于中国区账户并检查 DNS、系统时间和 TLS 证书，不要关闭证书验证。
- Hex、npm 或源码依赖下载失败：可临时设置可信代理的 `HTTPS_PROXY`/`HTTP_PROXY`，或使用组织内经过校验的镜像；不要关闭 TLS 校验，也不要运行来源不明的一键换源脚本。
- 数据库锁或连接过多：确认没有同时启动多个 TeslaMate 实例，并检查 `DATABASE_POOL_SIZE`。
