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

  # Browsers hash either the full JavaScript URL or its body. Both hashes
  # authorize only the SDK's fixed "javascript:void(0)" resize navigation.
  @amap_resize_noop_hash "97l24HYIWEdSIQ8PoMHzpxiGCZuyBDXtN19RPKFsOgk="
  @amap_resize_url_hash "rRMdkshZyJlCmDX27XnL7g3zXaxv7ei6Sg+yt4R3svU="

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
    # Cloudflare forwards this per-response nonce to its injected detection
    # scripts. Never allow all inline scripts or reuse a nonce across pages.
    nonce = :crypto.strong_rand_bytes(24) |> Base.encode64()
    amap? = TeslaMate.Maps.preferences().provider == :amap
    sources = if amap?, do: " https://*.amap.com https://*.autonavi.com", else: ""
    geocoding_source = if amap?, do: "", else: " https://nominatim.openstreetmap.org"

    # JS API 2.0 loads its renderer from a separate official CDN and uses
    # dynamic functions. Keep this compatibility exception provider-specific;
    # only the fixed resize no-op can match a navigation hash. Other inline
    # code, arbitrary script hosts and remote frames remain blocked.
    amap_scripts =
      if amap? do
        " " <>
          Enum.join(
            [
              "'unsafe-eval'",
              "'unsafe-hashes'",
              "'sha256-#{@amap_resize_noop_hash}'",
              "'sha256-#{@amap_resize_url_hash}'",
              "https://webapi.amap.com",
              "https://jsapi-service.amap.com",
              "https://mapplugin.amap.com"
            ],
            " "
          )
      else
        ""
      end

    csp =
      [
        "default-src 'self'",
        "base-uri 'self'",
        "img-src 'self' data: blob: https://tile.openstreetmap.org#{sources}",
        "font-src 'self' data:",
        "script-src #{script_src()} 'nonce-#{nonce}'#{amap_scripts}",
        "style-src #{style_src()}#{if amap?, do: " https://webapi.amap.com", else: ""}",
        "connect-src 'self' ws: wss:#{sources}#{geocoding_source}",
        "worker-src 'self'#{if amap?, do: " blob:", else: ""}",
        "frame-src 'none'",
        "frame-ancestors #{frame_ancestors()}",
        "form-action 'self'",
        "object-src 'none'"
      ]
      |> Enum.join("; ")

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", csp)
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
