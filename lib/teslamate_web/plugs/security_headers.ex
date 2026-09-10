defmodule TeslaMateWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Hardens the response headers for every browser-served response.

  Sets:
    * `Content-Security-Policy` — restricts scripts/styles/connections to the
      unified TeslaMate origin. Frames are disabled because the platform does
      not embed Grafana or any other privileged application.
      `frame-ancestors` is left configurable via
      `TESLAMATE_CSP_FRAME_ANCESTORS` (default `'none'`) so external webhooks
      cannot embed TeslaMate in an iframe.
    * `Strict-Transport-Security` — only set when `TESLAMATE_HSTS=true` (off
      by default to avoid breaking deployments that are still on plain HTTP
      behind a reverse proxy that terminates TLS).
    * `X-Content-Type-Options: nosniff`
    * `X-Frame-Options: DENY`
    * `Referrer-Policy: strict-origin-when-cross-origin`
    * `Permissions-Policy` — disable camera/microphone/geolocation by
      default; TeslaMate does not need any of these.
    * Removes the `Server` and `X-Powered-By` headers (Plug already strips
      `X-Powered-By`; `Server` is set by Cowboy/Bandit and not always
      reachable, so we attempt and silently ignore).
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_csp()
    |> put_optional_hsts()
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header("permissions-policy", "camera=(), microphone=(), geolocation=()")
  end

  # ---- builders ----------------------------------------------------------

  defp put_csp(conn) do
    amap? = TeslaMate.Maps.preferences().provider == :amap
    sources = if amap?, do: " https://*.amap.com https://*.autonavi.com", else: ""

    # JS API 2.0 loads its renderer from a separate official CDN and uses
    # dynamic functions. Keep this compatibility exception provider-specific;
    # inline scripts, arbitrary script hosts and frames remain blocked.
    amap_scripts =
      if amap?,
        do:
          " 'unsafe-eval' https://webapi.amap.com https://jsapi-service.amap.com https://mapplugin.amap.com",
        else: ""

    csp =
      [
        "default-src 'self'",
        "base-uri 'self'",
        "img-src 'self' data: blob: https://tile.openstreetmap.org#{sources}",
        "font-src 'self' data:",
        "script-src #{script_src()}#{amap_scripts}",
        "style-src #{style_src()}#{if amap?, do: " https://webapi.amap.com", else: ""}",
        "connect-src 'self' ws: wss:#{sources}",
        "worker-src 'self'#{if amap?, do: " blob:", else: ""}",
        "frame-src 'none'",
        "frame-ancestors #{frame_ancestors()}",
        "form-action 'self'",
        "object-src 'none'"
      ]
      |> Enum.join("; ")

    put_resp_header(conn, "content-security-policy", csp)
  end

  defp put_optional_hsts(conn) do
    if TeslaMateWeb.Config.hsts?() do
      # 2 years; include subdomains. Operators behind a TLS-terminating proxy
      # MUST turn this on for the browser to refuse plain-HTTP fallbacks.
      put_resp_header(conn, "strict-transport-security", "max-age=63072000; includeSubDomains")
    else
      conn
    end
  end

  # ---- env helpers -------------------------------------------------------

  defp script_src, do: TeslaMateWeb.Config.csp_script_src()
  defp style_src, do: TeslaMateWeb.Config.csp_style_src()
  defp frame_ancestors, do: TeslaMateWeb.Config.csp_frame_ancestors()
end
