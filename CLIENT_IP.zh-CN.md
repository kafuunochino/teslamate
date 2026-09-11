# 反向代理与真实客户端 IP

登录设备显示 `::ffff:172.18.0.1`，表示应用看到的是 Docker 网关连接，而非用户访问时的公网 IP。`::ffff:` 是 IPv4 映射到 IPv6 的表示方式。本项目会在代理匹配和显示时将它转换为普通 IPv4，`172.18.0.1` 的配置同时适用于两种表示。

## 1Panel / OpenResty 配置

在应用的 `.env` 中，将实际直连应用的代理地址加入白名单。例如应用看到的代理确实为 `::ffff:172.18.0.1` 时：

```dotenv
TESLAMATE_TRUSTED_PROXIES=172.18.0.1
```

多个代理地址用逗号分隔。支持 IPv4、IPv6 和 CIDR；优先使用单个代理地址。不要使用 `0.0.0.0/0`、`::/0`，也不要将包含普通客户端或不受信任容器的整个网络加入白名单。默认不信任任何代理，不能通过随意传入请求头改变 IP。

若 OpenResty 直接面向公网，在对应反向代理的 `location` 内转发真实来源：

```nginx
proxy_set_header X-Forwarded-For $remote_addr;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-Proto $scheme;
```

如果前面还有 CDN 或负载均衡，应先在 OpenResty 中正确配置上游可信代理的真实 IP 解析，再传递解析后的地址；或者每层代理向 `X-Forwarded-For` 追加实际连接来源，并在应用中明确列出每个可信代理。不能直接原样转发用户提供的请求头。

应用端口应仅供代理访问。项目的 1Panel Compose 默认只绑定 `127.0.0.1:3000`，容器网络也应限制在受控服务范围内。

`.env` 修改后需要重新创建应用容器才会生效，仅重启已有容器不会更新环境变量。使用原有部署的全部 Compose 文件和环境文件执行更新，保留数据库及卷；不要为修复 IP 重新初始化数据库。

## 解析规则

1. 先核对实际连接来源是否属于可信代理，IPv4 映射地址按 IPv4 进行匹配。
2. 将所有 `X-Forwarded-For` 头按顺序组成一条链，从右向左跳过可信代理，在第一个不受信任的地址停止。这个地址是可验证的来源；不能盲目选择最左侧的值。
3. 遇到非法地址立即停止，不跨过它去采用前面的值。
4. 只有 `X-Forwarded-For` 完全缺失时，才接受可信代理提供的单个有效 `X-Real-IP`。重复、空值或不合法的头不会成为回退捷径。
5. 没有有效转发信息时保留实际连接 IP。HTTP 登录、两步验证完成后的设备记录、登录审计、限流和 LiveView 会话使用同一规则。

代理链处理参考 [MDN 的 X-Forwarded-For 说明](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/X-Forwarded-For)；OpenResty 上游地址解析参考 [Nginx realip 模块](https://nginx.org/en/docs/http/ngx_http_realip_module.html)。

## 验证与历史记录

更新部署后，在新会话中登录，进入「账号设置 → 在线设备与登录会话」检查 IP。可分别用家庭网络和手机流量登录，确认两条新会话记录各自的网络出口；没有独立公网地址的设备会显示运营商或路由器的出口 IP。

旧会话只保存了当时记录的 IP，无法从网关地址恢复原公网地址。本次修复不会伪造或批量改写旧记录，也不会强制登出全部设备。退出并重新登录后，新记录会使用修正后的解析结果。

若新会话仍显示 `172.18.0.1`，检查应用容器中的 `TESLAMATE_TRUSTED_PROXIES` 是否生效、是否与实际代理一致，以及 OpenResty 是否发送了正确的头。不要通过放开所有来源来隐藏配置问题。
