# 人机验证配置

管理员在「系统设置 → 人机验证」选择 Cloudflare Turnstile、阿里云验证码 2.0 或腾讯云验证码 2.0。只有点击「验证并保存」才会应用。首次配置或修改凭据时，会打开验证页；完成真实挑战并由服务端校验通过后才保存。验证失败或取消不会改变当前配置。

各厂商的配置独立保留。切换到以前保存过的厂商时无需重新填写，密钥输入框留空表示保留已有值。服务器重启后配置仍在。密钥不会回显到设置表单，并使用部署的 `ENCRYPTION_KEY` 加密存储；备份与迁移时必须同时保留数据库和原加密密钥。

## 所需配置

| 厂商                 | 必填内容                                                       |
| -------------------- | -------------------------------------------------------------- |
| Cloudflare Turnstile | Site Key、Secret Key、允许的网站域名（不含协议或路径）         |
| 阿里云验证码 2.0     | 地域、身份标 prefix、Web/H5 场景 ID、RAM AccessKey ID / Secret |
| 腾讯云验证码 2.0     | CaptchaAppId、AppSecretKey、云 API SecretId / SecretKey        |

在厂商控制台授权实际访问本站的域名。阿里云使用 V3 架构，前后端地域必须一致，关闭场景的测试放行模式，建议选择交互式验证。腾讯云使用普通 CaptchaAppId，暂不支持控制台的强制 CaptchaAppId 加密鉴权选项。使用具备验证码调用权限的子账号凭据。

注册始终需要验证（启用时），登录失败一次后需要验证；密码、两步验证码和邀请码仍会独立校验。浏览器中的验证结果必须在服务端再次校验，不能仅凭前端成功回调放行。过期、重复票据、厂商测试放行、腾讯容灾票据、网络超时或接口错误均不放行。切换厂商后，旧页面需要刷新。

首次升级会继续使用原有 `TESLAMATE_TURNSTILE_*` 环境配置，避免升级时关闭已启用的验证。第一次保存厂商配置时会保留已有 CF 凭据；此后已保存的数据库配置优先于环境变量。

服务端请求使用固定的官方 HTTPS 地址和带签名的接口，不接收自定义接口 URL。配置验证页面不缓存，待验证配置使用加密令牌，有效期十分钟、绑定当前管理员，且新保存会使之前的配置草稿失效。数据库迁移只添加 `private.captcha_settings`，不修改账号、车辆、历史数据或已有环境文件。

## 官方接入资料

- [阿里云 Web/H5 V3](https://help.aliyun.com/zh/captcha/captcha2-0/user-guide/new-architecture-for-web-and-h5-client-access)
- [阿里云服务端 HTTPS 接入](https://help.aliyun.com/zh/captcha/captcha2-0/use-cases/server-api-access)
- [阿里云 ACS3 签名](https://help.aliyun.com/zh/sdk/product-overview/v3-request-structure-and-signature)
- [腾讯云 Web 客户端](https://cloud.tencent.com/document/product/1110/36841)
- [腾讯云票据校验](https://cloud.tencent.com/document/api/1110/36926)
- [腾讯云 TC3 签名](https://cloud.tencent.com/document/api/213/30654)
