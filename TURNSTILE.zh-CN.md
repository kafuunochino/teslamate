# 注册与登录人机验证

在 Cloudflare 控制台的 Turnstile 中创建「托管」小组件，绑定实际访问域名，例如 `vehicles.example.com`；不需要开启预清除。将以下配置加入服务器 `.env`（权限设为 `600`），然后重新创建应用容器：

```dotenv
TESLAMATE_TURNSTILE_ENABLED=true
TESLAMATE_TURNSTILE_SITE_KEY=填写站点密钥
TESLAMATE_TURNSTILE_SECRET_KEY=填写私有密钥
TESLAMATE_TURNSTILE_HOSTNAMES=vehicles.example.com
```

域名只填主机名，不含协议、端口或路径；多个域名用逗号分隔。私有密钥只用于服务器调用，不提交到 GitHub，也不会渲染到页面。两个中文 Compose 部署文件均已传入这些变量。未配置的新安装默认关闭；启用后缺少配置会阻止受保护的提交，避免意外放行。

- 注册开关由管理员控制；开放注册时，每次提交都需验证。
- 首次登录无需验证。密码或两步验证码失败一次后，同一 IP 或邮箱在登录限流窗口内的重试必须验证，默认窗口为 10 分钟。刷新页面、清除 Cookie 或切换 IP 不能清除邮箱的失败记录；更换邮箱也不能清除 IP 的失败记录。
- 完成登录后清除该邮箱及当前 IP 的人机验证要求，但保留 IP 的原有限流计数。失败记录存于当前应用节点内存，应用重启后重置；多副本部署需要改用共享存储。
- 两步验证依旧单独校验动态码或恢复码，人机验证不能代替两步验证。
- 后端向 Cloudflare Siteverify 校验结果、用途和域名；缺失、过期、重复使用或不匹配的令牌均不放行。网络异常时可刷新重试。
- 验证框跟随页面深浅色，窄屏使用紧凑布局；脚本加载失败、超时或验证过期时会显示重试入口。

上线检查：注册页显示组件；第一次输错密码后出现组件；不带验证令牌直接重试仍被拒绝；通过验证后仍须提供正确密码及已启用的两步验证码。检查仅登录、注册和两步验证页面的 CSP 允许 `challenges.cloudflare.com`，其他页面维持原有框架限制。

接入依据：[Cloudflare 服务端验证文档](https://developers.cloudflare.com/turnstile/get-started/server-side-validation/)。
