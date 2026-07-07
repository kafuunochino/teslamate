defmodule TeslaMateWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :teslamate

  @session_options [
    store: :cookie,
    key: "_teslamate_key",
    signing_salt: "yt5O3CAQ",
    same_site: "Strict"
  ]

  plug TeslaMateWeb.HealthCheck

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [
        session: @session_options,
        peer_data: true,
        # Pull the real client IP from `X-Forwarded-For` when running behind
        # a reverse proxy (Nginx, Cloudflare, Caddy, etc.).
        x_headers: true
      ],
      transport_log: :debug
    ]

  plug Plug.Static,
    at: "/",
    from: :teslamate,
    encodings: [{"zstd", ".zst"}, {"br", ".br"}, {"gzip", ".gz"}],
    only: TeslaMateWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :teslamate
  end

  plug Plug.RequestId
  plug Plug.Logger

  # Optional: redirect HTTP -> HTTPS. Off by default so plain-HTTP LAN
  # deployments keep working. Enable by setting `TESLAMATE_FORCE_SSL=true`
  # in `.env` when running behind a TLS-terminating reverse proxy.
  if TeslaMateWeb.Config.force_ssl?() do
    plug Plug.SSL,
      rewrite_on: [:x_forwarded_proto],
      host: nil,
      hsts: false
  end

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug TeslaMateWeb.Router
end
