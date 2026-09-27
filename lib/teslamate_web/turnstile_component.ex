defmodule TeslaMateWeb.TurnstileComponent do
  use Phoenix.Component

  alias TeslaMate.Auth.{Captcha, CaptchaSettings}

  attr :conn, :any, required: true
  attr :action, :string, required: true
  attr :email, :string, default: nil

  def turnstile(assigns) do
    settings = CaptchaSettings.active()
    ip = assigns.conn.private[:client_ip] || "unknown"

    assigns =
      assigns
      |> assign(:required, Captcha.required?(settings, ip, assigns.action, assigns.email))
      |> assign(:configured, CaptchaSettings.configured?(settings.provider, settings.config))
      |> assign(:settings, CaptchaSettings.public_config(settings))

    ~H"""
    <.challenge :if={@required} settings={@settings} configured={@configured} action={@action} />
    """
  end

  attr :settings, :map, required: true
  attr :configured, :boolean, default: true
  attr :action, :string, required: true

  def challenge(assigns) do

    ~H"""
    <div
      :if={@settings.provider == "cloudflare"}
      class="auth-verification"
      data-turnstile
      data-sitekey={@settings.config["site_key"]}
      data-action={@action}
      data-configured={to_string(@configured)}
    >
      <input type="hidden" name="captcha_provider" value={@settings.provider} />
      <input type="hidden" name="captcha_revision" value={@settings.revision} />
      <p class="help">请完成人机验证后继续。</p>
      <div data-turnstile-widget></div>
      <p data-turnstile-status class="help" role="status" aria-live="polite">
        <%= if @configured, do: "正在加载人机验证…", else: Captcha.message(:unavailable) %>
      </p>
      <button type="button" class="button is-small" data-turnstile-retry hidden>重新加载验证</button>
      <noscript>
        <p class="auth-alert">请启用 JavaScript 以完成人机验证。</p>
      </noscript>
    </div>
    <div :if={@settings.provider in ["aliyun", "tencent"]} class="auth-verification" data-captcha
      data-provider={@settings.provider} data-configured={to_string(@configured)}
      data-region={@settings.config["region"]} data-prefix={@settings.config["prefix"]}
      data-scene={@settings.config["scene_id"]} data-app-id={@settings.config["app_id"]}>
      <input type="hidden" name="captcha_provider" value={@settings.provider} />
      <input type="hidden" name="captcha_revision" value={@settings.revision} />
      <input type="hidden" name="captcha_token" value="" data-captcha-token />
      <input type="hidden" name="captcha_randstr" value="" data-captcha-randstr />
      <p class="help">请完成人机验证后继续（<%= CaptchaSettings.label(@settings.provider) %>）。</p>
      <div id="captcha-widget" data-captcha-widget></div>
      <button id="captcha-trigger" type="button" class="button is-fullwidth" data-captcha-trigger disabled>点击完成人机验证</button>
      <p data-captcha-status class="help" role="status" aria-live="polite">
        <%= if @configured, do: "正在加载人机验证…", else: Captcha.message(:unavailable) %>
      </p>
      <button type="button" class="button is-small" data-captcha-retry hidden>重新加载验证</button>
      <noscript><p class="auth-alert">请启用 JavaScript 以完成人机验证。</p></noscript>
    </div>
    """
  end
end
