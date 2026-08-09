# 1Panel 无损升级指南：双端口部署迁移到统一 3000

本指南适用于当前服务器已有以下资源的部署：

- TeslaMate 运行在 `127.0.0.1:4000`；
- Grafana 运行在 `127.0.0.1:3000`；
- PostgreSQL 是外部现有服务，容器内使用 `postgres:5432`；
- Nginx/1Panel 把公网 HTTPS 域名代理到 `127.0.0.1:3000`；
- 已有 Grafana 数据卷；它的 Docker 实际名称可能带 Compose 项目前缀，例如
  `teslamate-cn_teslamate-grafana-data`。

升级后的统一应用接管宿主机 3000，4000 不再发布。旧 Grafana 只停止并移除容器，其数据卷、用户、仪表板和 SQLite 数据均保留。TeslaMate 遥测数据继续使用原 PostgreSQL。

## 迁移改变了什么

| 项目       | 升级前                            | 升级后                         |
| ---------- | --------------------------------- | ------------------------------ |
| 公网应用   | Grafana                           | TeslaMate CN 统一平台          |
| 宿主机端口 | Grafana 3000 + TeslaMate 4000     | 仅 `127.0.0.1:3000`            |
| 平台登录   | Grafana 账号或旧 Tesla token 页面 | 独立平台账号、注册与会话       |
| 车辆权限   | Grafana 组织/全局访问             | 管理员全车；普通用户按车辆授权 |
| PostgreSQL | 外部 `postgres:5432`              | 原地址、原库、原数据           |
| Grafana 卷 | 运行中，名称可能带项目前缀        | 精确原名保留，默认不挂载运行   |

新增迁移版本为 `20260801090000`，只创建：

```text
private.users
private.user_sessions
private.user_cars
private.vehicle_claims
private.audit_events
```

迁移不会 `DELETE`、`TRUNCATE` 或重建 `cars`、`drives`、`positions`、`charging_processes`、`charges`、`addresses`、`geofences`、`tokens`。

## 一、升级前检查与备份

在服务器执行：

```bash
cd /opt/teslamate-cn
set -e

OLD_COMMIT="$(git rev-parse HEAD)"
BACKUP_DIR="/opt/teslamate-upgrade-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
printf '%s\n' "$BACKUP_DIR" > /opt/teslamate-upgrade-current.path
chmod 600 /opt/teslamate-upgrade-current.path

printf '%s\n' "$OLD_COMMIT" > "$BACKUP_DIR/old.commit"
cp -a .env "$BACKUP_DIR/env.before"
cp -a docker-compose.1panel.yml "$BACKUP_DIR/docker-compose.1panel.before.yml"
for LOCAL_BACKUP in .env.bak.* docker-compose.1panel.yml.bak.*; do
  [ ! -e "$LOCAL_BACKUP" ] || cp -a "$LOCAL_BACKUP" "$BACKUP_DIR/"
done

docker compose -f docker-compose.1panel.yml config \
  > "$BACKUP_DIR/compose.effective.before.yml"
docker compose -f docker-compose.1panel.yml ps \
  > "$BACKUP_DIR/containers.before.txt"

# 从正在运行的旧容器检测真实卷名，不能根据 Compose 中的逻辑名称猜测。
GRAFANA_CONTAINER="$(docker compose -f docker-compose.1panel.yml ps -q grafana)"
test -n "$GRAFANA_CONTAINER"
GRAFANA_VOLUME_NAME="$(docker inspect "$GRAFANA_CONTAINER" --format \
  '{{range .Mounts}}{{if eq .Destination "/var/lib/grafana"}}{{.Name}}{{end}}{{end}}')"
test -n "$GRAFANA_VOLUME_NAME"
printf '%s\n' "$GRAFANA_VOLUME_NAME" > "$BACKUP_DIR/grafana-volume.name"
docker volume inspect "$GRAFANA_VOLUME_NAME" \
  > "$BACKUP_DIR/grafana-volume.before.json"

chmod 600 "$BACKUP_DIR"/*
git status --short
```

先核对所有输出。已知的 `.env.bak.*` 和 `docker-compose.1panel.yml.bak.*`
可以保留，但必须已复制到 `$BACKUP_DIR`；若有其他未知修改，停止升级。不要让
`git pull` 覆盖人工修改。

确认外部 PostgreSQL 的网络和别名：

```bash
docker inspect <PostgreSQL容器名> --format '{{json .NetworkSettings.Networks}}'
```

`PANEL_NETWORK` 必须选择一个已经连接 PostgreSQL、且其中存在
`DATABASE_HOST` 对应 DNS 别名的网络。例如 `DATABASE_HOST=postgres` 只在
`teslamate-cn_default` 上显示别名 `postgres` 时，应设置
`PANEL_NETWORK=teslamate-cn_default`，不要把数据库主机名改成另一个值。

创建外部 PostgreSQL 自定义格式备份。把 `<PostgreSQL容器名>` 替换为真实容器名；不要改数据库密码、主机或库名：

```bash
DB_BACKUP="$BACKUP_DIR/teslamate-before.dump"
docker exec <PostgreSQL容器名> \
  pg_dump -U teslamate -d teslamate -Fc > "$DB_BACKUP"
test -s "$DB_BACKUP"

docker exec <PostgreSQL容器名> \
  pg_restore --list - < "$DB_BACKUP" >/dev/null
```

记录关键遥测行数，升级后对比：

```bash
docker exec <PostgreSQL容器名> psql -U teslamate -d teslamate -Atc \
  "SELECT 'cars='||count(*) FROM cars
   UNION ALL SELECT 'drives='||count(*) FROM drives
   UNION ALL SELECT 'positions='||count(*) FROM positions
   UNION ALL SELECT 'charging_processes='||count(*) FROM charging_processes;" \
  | tee "$BACKUP_DIR/telemetry-counts.before.txt"
```

`grafana-volume.before.json` 和 `grafana-volume.name` 已保存真实卷信息。迁移后
所有卷检查都必须读取这个名称，不能硬编码逻辑名称。

若 SSH 会话中断，先执行下面两行恢复本指南使用的变量，再继续当前章节：

```bash
BACKUP_DIR="$(cat /opt/teslamate-upgrade-current.path)"
test -d "$BACKUP_DIR"
```

## 二、处理仓库中的 1Panel Compose 文件

旧服务器的 `docker-compose.1panel.yml` 通常是未跟踪文件；新版本开始由仓库维护同名文件。先把旧文件移出工作树，避免 `git pull` 因“untracked working tree file would be overwritten”失败：

```bash
set -e
BACKUP_DIR="$(cat /opt/teslamate-upgrade-current.path)"
test -d "$BACKUP_DIR"

if ! git ls-files --error-unmatch docker-compose.1panel.yml >/dev/null 2>&1; then
  mv docker-compose.1panel.yml "$BACKUP_DIR/docker-compose.1panel.local.yml"
fi

git fetch origin
git pull --ff-only origin main
git rev-parse HEAD | tee "$BACKUP_DIR/new.commit"
```

若 `git pull --ff-only` 拒绝执行，不要使用 `git reset --hard`。检查本地分支/提交并人工处理。

## 三、补充环境变量

保留原 `.env` 中以下值，绝不重新生成或修改：

```text
ENCRYPTION_KEY
DATABASE_PASS
DATABASE_HOST
DATABASE_NAME
```

只为新平台增加两个稳定密钥，并固定刚才检测到的 Grafana 真实卷名。以下命令
不会覆盖已有密钥；若 `.env` 已配置了不同的 Grafana 卷名，会中止而不是猜测：

```bash
set -e
BACKUP_DIR="$(cat /opt/teslamate-upgrade-current.path)"
test -d "$BACKUP_DIR"

grep -q '^SECRET_KEY_BASE=' .env || \
  printf 'SECRET_KEY_BASE=%s\n' "$(openssl rand -base64 64 | tr -d '\n')" >> .env

grep -q '^SIGNING_SALT=' .env || \
  printf 'SIGNING_SALT=%s\n' "$(openssl rand -base64 32 | tr -d '\n')" >> .env

DETECTED_GRAFANA_VOLUME="$(cat "$BACKUP_DIR/grafana-volume.name")"
CONFIGURED_GRAFANA_VOLUME="$(sed -n 's/^GRAFANA_VOLUME_NAME=//p' .env | tail -n 1)"
if [ -n "$CONFIGURED_GRAFANA_VOLUME" ] && \
   [ "$CONFIGURED_GRAFANA_VOLUME" != "$DETECTED_GRAFANA_VOLUME" ]; then
  echo 'GRAFANA_VOLUME_NAME 与旧容器实际挂载不一致，停止升级'
  exit 1
fi
grep -q '^GRAFANA_VOLUME_NAME=' .env || \
  printf 'GRAFANA_VOLUME_NAME=%s\n' "$DETECTED_GRAFANA_VOLUME" >> .env

chmod 600 .env
```

编辑 `.env`，确认或新增：

```dotenv
DATABASE_USER=teslamate
DATABASE_HOST=postgres
DATABASE_PORT=5432
DATABASE_NAME=teslamate
# 必须是 DATABASE_HOST 在其中确实存在相同 DNS 别名的网络
PANEL_NETWORK=实际匹配网络
GRAFANA_VOLUME_NAME=上一步检测出的真实卷名

VIRTUAL_HOST=你的公网域名
CHECK_ORIGIN=https://你的公网域名
TESLAMATE_API_ORIGIN_CHECK=true
TESLAMATE_TRUSTED_PROXIES=1Panel反向代理容器IP或网段

# 首次切换时先关闭，管理员创建并验证后再开启
TESLAMATE_ALLOW_SIGN_UP=false
TESLAMATE_ACCOUNT_SESSION_DAYS=30
```

不要把 `.env`、数据库备份或上面的 `$BACKUP_DIR` 提交到 Git。

## 四、切换端口并启动统一平台

先验证新 Compose。它必须只列出外部 PostgreSQL 连接，不能有 `database` 服务：

```bash
set -e
BACKUP_DIR="$(cat /opt/teslamate-upgrade-current.path)"
test -d "$BACKUP_DIR"
COMPOSE_FILE=docker-compose.1panel.yml

docker compose -f "$COMPOSE_FILE" config > /tmp/teslamate-compose-check.yml
docker compose -f "$COMPOSE_FILE" --profile legacy-grafana config \
  > /tmp/teslamate-compose-legacy-check.yml
docker compose -f "$COMPOSE_FILE" config --services
grep -n '127.0.0.1:3000' /tmp/teslamate-compose-check.yml
EXPECTED_GRAFANA_VOLUME="$(cat "$BACKUP_DIR/grafana-volume.name")"
RESOLVED_GRAFANA_VOLUME="$(sed -n \
  '/^  teslamate-grafana-data:$/,/^  [^ ]/s/^    name: //p' \
  /tmp/teslamate-compose-legacy-check.yml)"
test "$RESOLVED_GRAFANA_VOLUME" = "$EXPECTED_GRAFANA_VOLUME"
docker volume inspect "$EXPECTED_GRAFANA_VOLUME" >/dev/null
if grep -n '4000:4000' /tmp/teslamate-compose-check.yml; then
  echo '检测到旧 4000 映射，停止升级'
  exit 1
fi
```

构建统一应用。此时旧容器仍在服务，不会提前中断：

```bash
TESLAMATE_REVISION="$(git rev-parse HEAD)" \
  docker compose -f "$COMPOSE_FILE" build --no-cache teslamate
```

旧 Grafana 占用宿主机 3000，必须先停止。停止后先通过 Docker API 把一致状态的
`/var/lib/grafana` 完整复制到备份目录；复制失败会恢复旧容器并中止，不会移除
数据卷：

```bash
GRAFANA_CONTAINER="$(docker compose -f "$COMPOSE_FILE" \
  --profile legacy-grafana ps -q grafana)"
test -n "$GRAFANA_CONTAINER"
docker compose -f "$COMPOSE_FILE" --profile legacy-grafana stop grafana

mkdir -p "$BACKUP_DIR/grafana-data.before"
if ! docker cp "$GRAFANA_CONTAINER:/var/lib/grafana/." \
  "$BACKUP_DIR/grafana-data.before/"; then
  docker start "$GRAFANA_CONTAINER"
  echo 'Grafana 数据复制失败，已恢复旧 Grafana，停止升级'
  exit 1
fi
if [ ! -s "$BACKUP_DIR/grafana-data.before/grafana.db" ]; then
  docker start "$GRAFANA_CONTAINER"
  echo '备份中没有有效 grafana.db，已恢复旧 Grafana，停止升级'
  exit 1
fi

docker compose -f "$COMPOSE_FILE" --profile legacy-grafana rm -f grafana
docker volume inspect "$(cat "$BACKUP_DIR/grafana-volume.name")" >/dev/null
```

只重新创建应用和 MQTT；入口脚本会自动执行增量数据库迁移：

```bash
docker compose -f "$COMPOSE_FILE" up -d --force-recreate mosquitto teslamate
docker compose -f "$COMPOSE_FILE" ps
docker compose -f "$COMPOSE_FILE" logs --tail=200 teslamate
```

不要执行 `docker compose down -v`。

## 五、创建首个平台管理员

管理员命令可重复执行：邮箱已存在时会把该账号恢复为有效管理员并更新密码。密码通过临时环境变量传入，不会写进仓库或 shell 历史：

```bash
read -r -p '管理员邮箱: ' ADMIN_EMAIL
read -r -s -p '管理员新密码（至少 12 位）: ' ADMIN_PASSWORD
printf '\n'

docker compose -f "$COMPOSE_FILE" exec \
  -e TESLAMATE_ADMIN_EMAIL="$ADMIN_EMAIL" \
  -e TESLAMATE_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -e TESLAMATE_ADMIN_NAME="平台管理员" \
  teslamate bin/teslamate eval 'TeslaMate.Release.create_admin_from_env()'

unset ADMIN_PASSWORD
```

预期输出包含：

```text
Administrator ready: ...
```

登录 HTTPS 域名后，管理员应能看到全部现有车辆、历史行程、充电和电池趋势。Tesla 采集 token 已使用原 `ENCRYPTION_KEY` 从原数据库读取，不需要重新输入；若此前没有有效 token，再进入“系统管理 → Tesla 连接”。

## 六、自动与人工验证

### 容器与端口

```bash
docker compose -f "$COMPOSE_FILE" ps
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/sign_in
curl -sS -o /dev/null -D - http://127.0.0.1:3000/ | sed -n '1,10p'
ss -ltn | grep -E '127\.0\.0\.1:(3000|4000)'
```

预期：

- `/sign_in` 返回 200；
- 未登录 `/` 返回 302 并跳转 `/sign_in`；
- 只有 `127.0.0.1:3000`，没有 4000；
- 默认 `ps` 中没有 Grafana；
- Nginx 原上游 `127.0.0.1:3000` 可直接显示平台登录页。

### 数据库与迁移

```bash
docker exec <PostgreSQL容器名> psql -U teslamate -d teslamate -Atc \
  "SELECT table_schema||'.'||table_name
   FROM information_schema.tables
   WHERE table_schema='private'
     AND table_name IN ('users','user_sessions','user_cars','vehicle_claims','audit_events')
   ORDER BY table_name;"

docker exec <PostgreSQL容器名> psql -U teslamate -d teslamate -Atc \
  "SELECT 'cars='||count(*) FROM cars
   UNION ALL SELECT 'drives='||count(*) FROM drives
   UNION ALL SELECT 'positions='||count(*) FROM positions
   UNION ALL SELECT 'charging_processes='||count(*) FROM charging_processes;" \
  | tee "$BACKUP_DIR/telemetry-counts.after.txt"
```

升级期间采集器可能继续新增少量记录，因此“after”应等于或大于“before”，不应减少。

### 权限隔离

人工执行一次最小验收：

1. 管理员登录，确认能选择全部车辆。
2. 临时把 `TESLAMATE_ALLOW_SIGN_UP=true` 后重建 `teslamate`，注册一个普通测试账号。
3. 测试账号首次登录必须显示“尚未绑定车辆”，不能枚举行程 URL 或 GPX。
4. 管理员为其中一辆车生成一次性认领码。
5. 测试账号兑换后只能看到该车；重复兑换相同认领码必须失败。
6. 管理员撤销车辆权限后，该账号刷新页面应立即失去访问。
7. 不需要公开注册时把 `TESLAMATE_ALLOW_SIGN_UP=false` 改回并重新创建应用。

```bash
docker compose -f "$COMPOSE_FILE" up -d --force-recreate teslamate
```

## 七、旧 Grafana 管理员密码

统一平台不使用 Grafana 密码。若迁移期需要查看旧卷，先临时启动无宿主机端口的 profile，再重置：

```bash
docker compose -f "$COMPOSE_FILE" --profile legacy-grafana up -d grafana
docker compose -f "$COMPOSE_FILE" --profile legacy-grafana exec grafana \
  grafana cli admin reset-admin-password '新的强密码'
```

Grafana 13 当前镜像推荐的兼容命令路径仍是 `grafana cli admin reset-admin-password`。完成后停止并移除容器即可，不能删除卷：

```bash
docker compose -f "$COMPOSE_FILE" --profile legacy-grafana stop grafana
docker compose -f "$COMPOSE_FILE" --profile legacy-grafana rm -f grafana
```

## 八、回滚（不删除任何卷）

本次账号迁移是纯增量表，旧代码会忽略这些表。因此应用回滚不需要删除表或恢复数据库；这样可以保留升级后新采集的遥测记录。

```bash
cd /opt/teslamate-cn
BACKUP_DIR="$(cat /opt/teslamate-upgrade-current.path)"
test -d "$BACKUP_DIR"
COMPOSE_FILE=docker-compose.1panel.yml

# 停止统一应用，保留所有卷和外部 PostgreSQL
docker compose -f "$COMPOSE_FILE" stop teslamate

OLD_COMMIT="$(cat "$BACKUP_DIR/old.commit")"
git switch --detach "$OLD_COMMIT"

# 恢复升级前的本地 Compose 与环境文件副本
cp -a "$BACKUP_DIR/docker-compose.1panel.before.yml" docker-compose.1panel.yml
cp -a "$BACKUP_DIR/env.before" .env

TESLAMATE_REVISION="$OLD_COMMIT" \
  docker compose -f docker-compose.1panel.yml up -d --build
```

此时会恢复旧的 Grafana 3000 和 TeslaMate 4000 行为；Nginx 仍指向 3000。
`grafana-volume.name` 中记录的原 Grafana 卷和 PostgreSQL 均未删除。

只有在数据库迁移本身异常且需要回到升级前的“完全一致状态”时，才考虑停止所有会写入数据库的 TeslaMate 实例并恢复 `$DB_BACKUP`。恢复备份会丢失备份后新增的遥测，必须由管理员单独确认，不能作为普通回滚步骤自动执行。

准备重试升级时：

```bash
git switch main
git pull --ff-only origin main
```

## 九、必须人工确认的事项

- 真实 PostgreSQL 容器名与用户是否为 `teslamate`；
- `DATABASE_HOST` 是否在 `PANEL_NETWORK` 上以同名网络别名可解析；
- 1Panel/Nginx 是否转发 WebSocket、`Host`、`X-Forwarded-Proto` 和 `X-Forwarded-For`；
- `CHECK_ORIGIN` 是否精确包含公网 HTTPS Origin；
- 首个管理员邮箱由谁保管，是否使用密码管理器中的独立强密码；
- 是否需要开放注册；若开放，是否接受当前版本尚无邮件验证/找回流程；
- OpenStreetMap 瓦片的外部请求是否符合你的轨迹隐私要求；
- `GRAFANA_VOLUME_NAME` 是否等于旧容器 `/var/lib/grafana` 的真实挂载卷；
- 旧 Grafana 卷需要保留多久以及是否已完成离线备份。
