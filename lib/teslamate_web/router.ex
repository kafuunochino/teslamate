defmodule TeslaMateWeb.Router do
  use TeslaMateWeb, :router

  alias TeslaMate.Settings

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash

    plug Cldr.Plug.AcceptLanguage,
      cldr_backend: TeslaMateWeb.Cldr,
      no_match_log_level: :debug

    plug Cldr.Plug.PutLocale,
      apps: [:cldr, :gettext],
      from: [:query, :session, :accept_language],
      gettext: TeslaMateWeb.Gettext,
      cldr: TeslaMateWeb.Cldr

    plug TeslaMateWeb.Plugs.PutSession

    plug :put_root_layout, {TeslaMateWeb.LayoutView, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_settings
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Light-touch auth gate. Always safe to apply (assigns :signed_in? and is a
  # no-op redirect-wise), so opting in by setting TESLAMATE_STRICT_AUTH=true
  # does not require any further route changes.
  pipeline :require_signed_in do
    plug TeslaMateWeb.Plugs.RequireSignedIn
  end

  # Reverse-proxy pipeline for the embedded Grafana dashboards. Phoenix does
  # not allow defining plugs at the scope level, so the proxy plug lives here.
  pipeline :grafana_proxy do
    plug TeslaMateWeb.Plugs.GrafanaProxy
  end

  # Runtime-configurable gate for /api/*. Reads TESLAMATE_PROTECT_API on every
  # request and either enforces the sign-in check or is a no-op.
  pipeline :api_gate do
    plug TeslaMateWeb.Plugs.ApiGate
  end

  scope "/", TeslaMateWeb do
    pipe_through :browser

    get "/", CarController, :index
    get "/drive/:id/gpx", DriveController, :gpx
  end

  # All LiveViews share a single live_session so navigation between pages does
  # not re-establish the session. The login page itself is always public; the
  # rest flow through `TeslaMateWeb.Plugs.RequireSignedIn`.
  #
  # That plug is a no-op by default and only enforces the redirect when the
  # operator opts in via `TESLAMATE_STRICT_AUTH=true`, so existing deployments
  # keep their prior behaviour automatically.
  live_session :default do
    scope "/", TeslaMateWeb do
      pipe_through :browser

      live "/sign_in", SignInLive.Index
    end

    scope "/", TeslaMateWeb do
      pipe_through [:browser, :require_signed_in]

      live "/settings", SettingsLive.Index
      live "/geo-fences", GeoFenceLive.Index
      live "/geo-fences/new", GeoFenceLive.Form
      live "/geo-fences/:id/edit", GeoFenceLive.Form
      live "/charge-cost/:id", ChargeLive.Cost
      live "/import", ImportLive.Index
    end
  end

  # The /api routes use a runtime check inside `TeslaMateWeb.Plugs.ApiGate`
  # rather than `if`-gating the `pipe_through`, because Phoenix resolves the
  # pipelines at compile time. Reading the env var at runtime means a user can
  # flip `TESLAMATE_PROTECT_API` without rebuilding.
  scope "/api", TeslaMateWeb do
    pipe_through [:api, :api_gate]

    put "/car/:id/logging/resume", CarController, :resume_logging
    put "/car/:id/logging/suspend", CarController, :suspend_logging
  end

  # Anything below /dashboards/* is the embedded Grafana reverse proxy. The
  # plug enforces the same auth gate as the rest of the browser and falls back
  # to a 302 redirect to the legacy port-3000 URL when EMBED_GRAFANA is off.
  scope "/dashboards", TeslaMateWeb do
    pipe_through [:browser, :require_signed_in, :grafana_proxy]
  end

  def fetch_settings(conn, _opts) do
    settings = Settings.get_global_settings!()

    conn
    |> assign(:settings, settings)
    |> put_session(:settings, settings)
  end
end
