defmodule TeslaMateWeb.TurnstileComponent do
  use Phoenix.Component

  alias TeslaMate.Auth.Turnstile
  alias TeslaMateWeb.Config

  attr :conn, :any, required: true
  attr :action, :string, required: true
  attr :email, :string, default: nil

  def turnstile(assigns) do
    ip = assigns.conn.private[:client_ip] || "unknown"

    assigns =
      assigns
      |> assign(:required, Turnstile.required?(ip, assigns.action, assigns.email))
      |> assign(:site_key, Config.turnstile_site_key())
      |> assign(:configured, Turnstile.configured?())

    ~H"""
    <div :if={@required} class="auth-verification" data-turnstile data-sitekey={@site_key} data-action={@action} data-configured={to_string(@configured)}>
      <p class="help">请完成人机验证后继续。</p>
      <div data-turnstile-widget></div>
      <p data-turnstile-status class="help" role="status" aria-live="polite">
        <%= if @configured, do: "正在加载人机验证…", else: Turnstile.message(:unavailable) %>
      </p>
      <button type="button" class="button is-small" data-turnstile-retry hidden>重新加载验证</button>
      <noscript><p class="auth-alert">请启用 JavaScript 以完成人机验证。</p></noscript>
    </div>
    """
  end
end
