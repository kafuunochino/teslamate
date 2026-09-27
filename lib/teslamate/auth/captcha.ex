defmodule TeslaMate.Auth.Captcha do
  @moduledoc "Authentication challenge policy and server-selected provider verification."
  alias TeslaMate.Auth.{CaptchaSettings, CaptchaVendors, Turnstile}
  alias TeslaMateWeb.Plugs.LoginRateLimit

  def required?(ip, action, email \\ nil) do
    required?(CaptchaSettings.active(), ip, action, email)
  end

  def required?(settings, ip, action, email) do
    not is_nil(settings.provider) and
      (action == "register" or LoginRateLimit.challenge_required?(ip, email))
  end

  def verify_if_required(params, ip, action, email \\ nil) do
    settings = CaptchaSettings.active()
    if required?(settings, ip, action, email), do: verify(settings, params, ip, action), else: :ok
  end

  def verify(%{provider: provider, config: config, revision: revision}, params, ip, action) do
    supplied_provider = params["captcha_provider"]
    supplied_revision = params["captcha_revision"]

    cond do
      not CaptchaSettings.configured?(provider, config) ->
        {:error, :unavailable}

      supplied_provider != provider and
          not (provider == "cloudflare" and is_nil(supplied_provider)) ->
        {:error, :invalid}

      supplied_revision != to_string(revision) and
          not (provider == "cloudflare" and is_nil(supplied_revision)) ->
        {:error, :invalid}

      provider == "cloudflare" ->
        Turnstile.verify(params["cf-turnstile-response"], ip, action, config)

      provider in ["aliyun", "tencent"] ->
        CaptchaVendors.verify(provider, config, params, ip)

      true ->
        {:error, :unavailable}
    end
  end

  def message(:configuration), do: "配置不完整或格式不正确，请填写该厂商所需的标识、密钥和域名。"
  def message(:expired), do: "配置验证已过期或设置已被更新，请返回系统设置重新验证。"
  def message(:test_mode), do: "阿里云场景仍处于测试放行模式，请在厂商控制台关闭测试模式后重新验证。"
  def message(:credentials), do: "厂商未接受当前凭据或调用权限，请检查密钥、服务开通状态及账号权限。"
  def message(reason), do: Turnstile.message(reason)
end
