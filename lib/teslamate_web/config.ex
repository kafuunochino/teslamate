defmodule TeslaMateWeb.Config do
  @moduledoc """
  Centralised runtime configuration for TeslaMate's security and embedding
  switches. Every getter reads its env var with a documented default and
  normalises the value to `true | false | string`. This guarantees that the
  `TESLAMATE_*` flags behave the same regardless of where they are consulted
  (router, plugs, LiveView, layout).

  ## Defaults policy

  Defaults favour **compatibility** for LAN deployments and **safety** for
  internet-facing deployments. The single switch you MUST set when going
  public is `TESLAMATE_TRUSTED_PROXIES` (otherwise `X-Forwarded-For` is
  trusted from any caller).

  See `.env.example` for the canonical list and recommended values.
  """

  # ---- boolean helpers ---------------------------------------------------

  @doc "Returns true iff `value` (case-insensitive) is in the truthy set."
  def truthy?(nil), do: false
  def truthy?(""), do: false

  def truthy?(value) when is_binary(value) do
    String.downcase(value) in ~w(1 true yes on)
  end

  def truthy?(value) when is_boolean(value), do: value

  def truthy?(_), do: false

  # ---- individual switches ----------------------------------------------

  @doc """
  Strict auth gate for browser routes. Default: `false` (backward
  compatibility with TeslaMate 1.x).

  Set to `true` when deploying behind a TLS reverse proxy on the internet.
  """
  def strict_auth?, do: truthy?(System.get_env("TESLAMATE_STRICT_AUTH", "false"))

  @doc """
  Require an authenticated session for `/api/car/:id/logging/{resume,suspend}`.
  Default: `false` (backward compatibility — those endpoints were public).

  Set to `true` for hardening. Note: the LiveView's UI depends on calling
  these endpoints, so as long as the browser has a session cookie the
  requests still succeed.
  """
  def protect_api?, do: truthy?(System.get_env("TESLAMATE_PROTECT_API", "false"))

  @doc """
  Reject mutating `/api/*` requests whose `Origin` or `Referer` does not
  match the host being hit. Default: `true`.

  Set to `false` only if you need to call the API from a different host
  with curl or programmatic clients (rare).
  """
  def api_origin_check?, do: truthy?(System.get_env("TESLAMATE_API_ORIGIN_CHECK", "true"))

  @doc """
  Force HTTP -> HTTPS redirect inside the TeslaMate process. Default: `false`.

  Recommended setting when TeslaMate is exposed directly (no reverse proxy).
  When behind a TLS-terminating reverse proxy, leave it `false` and let the
  proxy do the redirect.
  """
  def force_ssl?, do: truthy?(System.get_env("TESLAMATE_FORCE_SSL", "false"))

  @doc """
  Add `Strict-Transport-Security` to responses. Default: `false`.

  Only enable when TeslaMate is reachable **exclusively** over HTTPS — HSTS
  on a site that also serves HTTP will lock users out.
  """
  def hsts?, do: truthy?(System.get_env("TESLAMATE_HSTS", "false"))

  @doc """
  Reverse-proxy Grafana under `/dashboards/*`. Default: `true`.

  Disable when you want Grafana to remain on its own port (operator must
  then expose `:3000` and set `GRAFANA_PUBLIC_URL`).
  """
  def embed_grafana?, do: truthy?(System.get_env("EMBED_GRAFANA", "true"))

  # ---- rate limiting ----------------------------------------------------

  @default_max_per_ip 10
  @default_max_per_email 5
  @default_window_seconds 600
  @default_audit_capacity 100

  def max_login_per_ip, do: env_int("TESLAMATE_LOGIN_MAX_PER_IP", @default_max_per_ip)
  def max_login_per_email, do: env_int("TESLAMATE_LOGIN_MAX_PER_EMAIL", @default_max_per_email)
  def login_window_seconds, do: env_int("TESLAMATE_LOGIN_WINDOW_SECONDS", @default_window_seconds)
  def login_audit_capacity, do: env_int("TESLAMATE_LOGIN_AUDIT_CAPACITY", @default_audit_capacity)

  # ---- Grafana integration ---------------------------------------------

  def grafana_upstream, do: System.get_env("GRAFANA_UPSTREAM", "http://grafana:3000")
  def grafana_public_url, do: System.get_env("GRAFANA_PUBLIC_URL", "")
  def grafana_proxy_user, do: System.get_env("GRAFANA_PROXY_USER", "teslamate@local")
  def gf_server_root_url, do: System.get_env("GF_SERVER_ROOT_URL", "http://localhost:4000/dashboards")

  # ---- trusted proxies --------------------------------------------------

  @doc """
  Comma-separated list of upstream IPs / CIDRs whose `X-Forwarded-For`
  header is trusted. Default: `""` (empty), meaning **no proxy is trusted
  and the socket IP is used as-is**. Operators behind a reverse proxy MUST
  set this to the proxy's IP so that client IPs are resolved correctly.
  """
  def trusted_proxies, do: System.get_env("TESLAMATE_TRUSTED_PROXIES", "")

  # ---- CSP tuning -------------------------------------------------------

  def csp_script_src, do: System.get_env("TESLAMATE_CSP_SCRIPT_SRC", "'self' 'unsafe-inline' 'unsafe-eval'")
  def csp_style_src, do: System.get_env("TESLAMATE_CSP_STYLE_SRC", "'self' 'unsafe-inline'")
  def csp_frame_ancestors, do: System.get_env("TESLAMATE_CSP_FRAME_ANCESTORS", "'none'")

  # ---- internals --------------------------------------------------------

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      v ->
        case Integer.parse(v) do
          {n, ""} when n > 0 -> n
          _ -> default
        end
    end
  end
end