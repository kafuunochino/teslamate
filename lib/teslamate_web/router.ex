defmodule TeslaMateWeb.Router do
  use TeslaMateWeb, :router

  import TeslaMateWeb.UserAuth,
    only: [
      fetch_current_user: 2,
      redirect_if_authenticated: 2,
      require_admin: 2,
      require_authenticated_user: 2
    ]

  alias TeslaMate.Settings

  pipeline :browser do
    plug :accepts, ["html"]
    plug TeslaMateWeb.Plugs.ClientIP
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
    plug TeslaMateWeb.Plugs.SecurityHeaders
    plug :fetch_settings
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug TeslaMateWeb.Plugs.ClientIP
    plug :fetch_session
    plug :fetch_current_user
  end

  pipeline :redirect_if_authenticated do
    plug :redirect_if_authenticated
  end

  pipeline :require_user do
    plug :require_authenticated_user
  end

  pipeline :require_admin do
    plug :require_admin
  end

  pipeline :api_gate do
    plug TeslaMateWeb.Plugs.ApiGate
  end

  pipeline :api_origin_check do
    plug TeslaMateWeb.Plugs.ApiOriginCheck
  end

  scope "/", TeslaMateWeb do
    pipe_through [:browser, :redirect_if_authenticated]

    get "/sign_in", UserSessionController, :new
    post "/sign_in", UserSessionController, :create
    get "/register", UserRegistrationController, :new
    post "/register", UserRegistrationController, :create
  end

  scope "/", TeslaMateWeb do
    pipe_through [:browser, :require_user]

    delete "/sign_out", UserSessionController, :delete
    get "/account", UserSettingsController, :edit
    put "/account/profile", UserSettingsController, :update_profile
    put "/account/password", UserSettingsController, :update_password
    get "/drive/:id/gpx", DriveController, :gpx

    live_session :platform,
      on_mount: [
        {TeslaMateWeb.InitAssigns, :locale},
        {TeslaMateWeb.UserAuth, :ensure_authenticated}
      ] do
      live "/", DashboardLive.Home, :home, as: :dashboard
      live "/trips", DashboardLive.Trips, :trips, as: :dashboard
      live "/trips/:id", DashboardLive.Trip, :trip, as: :dashboard
      live "/battery", DashboardLive.Battery, :battery, as: :dashboard
      live "/charging", DashboardLive.Charging, :charging, as: :dashboard
      live "/analysis", DashboardLive.Analysis, :analysis, as: :dashboard
      live "/vehicles", VehicleLive.Index, :index
    end
  end

  scope "/admin", TeslaMateWeb do
    pipe_through [:browser, :require_user, :require_admin]

    # Keep legacy operational pages available to administrators while the
    # end-user UI is fully served by the unified platform above.
    get "/collector", CarController, :index

    live_session :platform_admin,
      on_mount: [
        {TeslaMateWeb.InitAssigns, :locale},
        {TeslaMateWeb.UserAuth, :ensure_admin}
      ] do
      live "/users", AdminLive.Users, :index
      live "/tesla-account", SignInLive.Index, :index
      live "/settings", SettingsLive.Index
      live "/geo-fences", GeoFenceLive.Index
      live "/geo-fences/new", GeoFenceLive.Form
      live "/geo-fences/:id/edit", GeoFenceLive.Form
      live "/charge-cost/:id", ChargeLive.Cost
      live "/import", ImportLive.Index
    end
  end

  scope "/api", TeslaMateWeb do
    pipe_through [:api, :api_gate, :api_origin_check]

    put "/car/:id/logging/resume", CarController, :resume_logging
    put "/car/:id/logging/suspend", CarController, :suspend_logging
  end

  def fetch_settings(conn, _opts) do
    settings = Settings.get_global_settings!()

    conn
    |> assign(:settings, settings)
    |> put_session(:settings, settings)
  end
end
