# 中国区增强功能迁移安全审计

## 审计范围

候选来源：`wjsall/teslamate-chinese-dashboards`，审计基线提交 `d8137ebce69cb7e00e956ef94e9f47fc73039dc0`。

本次检查覆盖：

- 45 个 Grafana 仪表盘 JSON；
- Dockerfile、GitHub Actions 和 Grafana provisioning；
- 3 组 PostgreSQL 扩展 SQL；
- 部署、升级、迁移、备份、诊断与分时电价脚本；
- 外部网络地址、第三方插件、密钥处理、数据库写入和高权限操作。

候选项目采用 AGPL-3.0，与 TeslaMate 的许可证兼容。移植文件经过修改，来源记录在 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 发现的风险

以下内容没有搬入本项目：

1. 一键部署、迁移和升级脚本：包含远程下载、Docker root 操作、系统定时任务及配置文件修改。
2. 密钥显示：候选部署脚本会在终端输出 `ENCRYPTION_KEY` 和数据库密码，容易进入终端日志、录屏或远程协助记录。
3. 带密钥备份：候选备份脚本默认复制含加密密钥的 Compose 配置；虽然会设置文件权限，但备份泄露后仍可能导致令牌暴露。
4. Volkov Labs 表单面板：需要安装第三方 Grafana 插件，并允许仪表盘执行数据库写入。
5. 分时电价写入面板：检测到直接执行 `UPDATE charging_processes`、`UPDATE tou_rates` 和 `DELETE FROM tou_rates` 的查询。
6. 高破坏性卸载函数：候选 SQL 含 `CASCADE` 删除对象和动态删除函数逻辑。
7. 自动加载的远程 GIF：打开仪表盘会连接第三方服务器，暴露网络地址和访问时间。
8. 覆盖官方同名仪表盘：候选版本可能落后于当前 TeslaMate；直接覆盖会丢失上游修复。

未发现把 Tesla API 令牌或数据库密码主动上传到外部服务器的明确代码，但这不等于对候选仓库未来版本作出保证。本项目不在运行时拉取或执行候选仓库内容。

## 实际迁移内容

- 保留当前 TeslaMate 的全部官方仪表盘，不覆盖同名文件。
- 新增 25 个候选项目独有的只读分析仪表盘。
- 对 5 个当前官方地图仪表盘进行最小增强，只增加受控地图源切换与查询时坐标纠偏，不替换其余面板逻辑。
- 仅允许 Grafana 内置面板类型；不依赖第三方表单面板。
- 所有新增仪表盘均通过静态检查，禁止 `INSERT`、`UPDATE`、`DELETE`、`DROP`、`ALTER`、`GRANT` 等写入 SQL。
- 分时电价改为 `tm_` 命名空间内的旁路表和函数：只把计算结果写入 `tm_charging_costs`，不改写 TeslaMate 原生 `charging_processes.cost`。
- 分时电价配置只能通过本地 `psql` 脚本显式执行；没有 Grafana 写入按钮，也没有危险的动态卸载函数。
- 移除远程 GIF；候选项目链接改为当前仓库链接。
- 地图源收敛为高德地图、高德卫星和 OpenStreetMap；删除在中国大陆通常不可用的 Google/Carto 选项。
- 坐标纠偏函数改用 `tm_` 前缀，并固定函数 `search_path`，降低对象劫持风险。
- 地图变量不与仪表盘 URL 同步，进入 SQL 前还会使用 Grafana `sqlstring` 转义，避免参数篡改和 SQL 注入。
- 增加 PostgreSQL 迁移测试，检查境内转换、境外不转换和非高德地图不转换。
- 为原生非 Docker 安装提供 `teslamate_grafana` 只读角色；明确拒绝访问保存加密令牌的 `private` schema。

运行以下命令可重复执行仪表盘安全检查：

```bash
node scripts/validate-china-dashboards.mjs
```

## 仍然存在的边界

- 高德或 OpenStreetMap 地图瓦片服务会收到访问者的网络地址、地图视野和缩放级别；不希望产生外部请求时不要打开地图类仪表盘。
- 只读 SQL 仍可能消耗大量数据库资源，因此只应允许可信管理员编辑仪表盘和数据源。
- Grafana、Elixir、PostgreSQL、Node.js 和操作系统本身仍需及时安装安全更新。
- 不应把 Grafana、TeslaMate 或 PostgreSQL 端口直接暴露到互联网。
