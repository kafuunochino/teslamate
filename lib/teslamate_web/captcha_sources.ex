defmodule TeslaMateWeb.CaptchaSources do
  @moduledoc false
  # Restricted to official CAPTCHA SDK/resource domains, only on challenge pages.
  def for_provider("cloudflare"), do: ["https://challenges.cloudflare.com"]

  def for_provider("tencent"),
    do: [
      "https://*.captcha.qcloud.com",
      "https://*.captcha.qq.com",
      "https://captcha.gtimg.com",
      "https://turing.captcha.gtimg.com"
    ]

  def for_provider("aliyun") do
    [
      "https://g.alicdn.com",
      "https://o.alicdn.com",
      "https://x.alicdn.com",
      "https://static-captcha.aliyuncs.com",
      "https://static-captcha-sgp.aliyuncs.com",
      "https://cloudauth-device-dualstack.cn-shanghai.aliyuncs.com",
      "https://cloudauth-device-dualstack.ap-southeast-1.aliyuncs.com"
    ] ++
      Enum.map(
        ~w(captcha-open captcha-open-b captcha-open-southeast captcha-open-southeast-b captcha-open-dual captcha-open-dual-b captcha-open-southeast-dual captcha-open-southeast-dual-b captcha-open-ga-web captcha-open-ga-web-b),
        &"https://*.#{&1}.aliyuncs.com"
      )
  end

  def for_provider(_), do: []
end
