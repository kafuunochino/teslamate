defmodule TeslaMateWeb.SettingsLive.CaptchaComponent do
  use TeslaMateWeb, :live_component
  alias TeslaMate.Auth.CaptchaSettings

  @fields %{
    "cloudflare" => [
      {"site_key", "Site Key", false},
      {"secret_key", "Secret Key", true},
      {"hostnames", "允许的网站域名（多个用英文逗号分隔）", false}
    ],
    "aliyun" => [
      {"prefix", "身份标识 prefix", false},
      {"scene_id", "场景 ID（SceneId）", false},
      {"access_key_id", "RAM AccessKey ID", true},
      {"access_key_secret", "RAM AccessKey Secret", true}
    ],
    "tencent" => [
      {"app_id", "验证码应用 ID（CaptchaAppId）", false},
      {"app_secret_key", "验证码应用密钥（AppSecretKey）", true},
      {"secret_id", "云 API SecretId", true},
      {"secret_key", "云 API SecretKey", true}
    ]
  }

  @impl true
  def update(_assigns, socket) do
    prefs = CaptchaSettings.preferences()
    provider = socket.assigns[:provider] || prefs.provider || "cloudflare"
    {:ok, assign(socket, prefs: prefs, provider: provider, fields: @fields[provider])}
  end

  @impl true
  def handle_event("provider", %{"captcha_settings" => %{"provider" => provider}}, socket) do
    if provider in CaptchaSettings.providers() do
      {:noreply, assign(socket, provider: provider, fields: @fields[provider])}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="columns is-mobile is-centered settings-layout" id="captcha-settings">
      <div class="column">
        <h2 class="title is-4">人机验证</h2>
        <p class="help mb-4" id="captcha-settings-current">
          当前使用：<%= CaptchaSettings.label(@prefs.provider) %>。注册时需要验证；登录失败一次后，后续尝试需要验证。
        </p>
        <.form
          :let={f}
          for={%{}}
          as={:captcha_settings}
          action="/admin/captcha"
          method="post"
          id="captcha-settings-form"
          autocomplete="off"
        >
          <div class="field">
            <%= label(f, :provider, "验证服务提供商", class: "label") %>
            <div class="control select is-fullwidth">
              <%= select(
                f,
                :provider,
                Enum.map(CaptchaSettings.providers(), &{CaptchaSettings.label(&1), &1}),
                value: @provider,
                phx_change: "provider",
                phx_target: @myself
              ) %>
            </div>
          </div>
          <div id={"captcha-fields-" <> @provider}>
            <p class="help mb-3">
              <%= if @prefs.profiles[@provider].saved,
                do: "已有保存的配置。无需修改时直接点击保存即可切换；密钥留空会保留。",
                else: "尚未配置。请填写以下信息，再点击验证并保存。" %>
            </p>
            <div :if={@provider == "aliyun"} class="field">
              <%= label(f, :region, "验证码地域", class: "label") %>
              <div class="control select is-fullwidth">
                <%= select(f, :region, [{"中国内地", "cn"}, {"新加坡", "sgp"}],
                  value: @prefs.profiles[@provider].values["region"] || "cn"
                ) %>
              </div>
            </div>
            <div :for={{key, title, secret?} <- @fields} class="field">
              <label class="label" for={"captcha-settings-" <> key}><%= title %></label>
              <div class="control">
                <input
                  id={"captcha-settings-" <> key}
                  name={"captcha_settings[" <> key <> "]"}
                  class="input"
                  type={if secret?, do: "password", else: "text"}
                  value={if secret?, do: "", else: @prefs.profiles[@provider].values[key] || ""}
                  placeholder={
                    if secret? and @prefs.profiles[@provider].secrets[key],
                      do: "已保存，留空保留",
                      else: "请输入"
                  }
                  maxlength="1024"
                  autocomplete={if secret?, do: "new-password", else: "off"}
                  spellcheck="false"
                />
              </div>
            </div>
            <p :if={@provider == "cloudflare"} class="help mb-4">
              在 <a
                href="https://dash.cloudflare.com/?to=/:account/turnstile"
                target="_blank"
                rel="noopener noreferrer"
              >Cloudflare Turnstile 控制台</a>创建站点。上方域名填写本站域名，不含 https://、端口或路径，并在厂商控制台授权该域名。
            </p>
            <p :if={@provider == "aliyun"} class="help mb-4">
              在 <a href="https://yundun.console.aliyun.com/" target="_blank" rel="noopener noreferrer">阿里云验证码控制台</a>开通验证码 2.0，创建 Web/H5 场景并授权本站域名。使用 V3 架构，关闭测试放行；推荐交互式验证。为 RAM 子账号授予验证码调用权限，填写该子账号的 AccessKey。
            </p>
            <p :if={@provider == "tencent"} class="help mb-4">
              在 <a
                href="https://console.cloud.tencent.com/captcha"
                target="_blank"
                rel="noopener noreferrer"
              >腾讯云验证码控制台</a>创建 Web 验证应用并授权本站域名。应用密钥和云 API 密钥是两组不同凭据；云 API 子账号需要 DescribeCaptchaResult 权限。当前接入使用普通 CaptchaAppId。
            </p>
            <p class="help mb-4">各厂商配置分别加密保存。选择或填写后不会立即切换；新配置须通过实际验证后才会启用。</p>
          </div>
          <button type="submit" class="button is-primary">验证并保存</button>
        </.form>
      </div>
    </section>
    """
  end
end
