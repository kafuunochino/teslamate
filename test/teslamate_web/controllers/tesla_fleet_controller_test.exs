defmodule TeslaMateWeb.TeslaFleetControllerTest do
  use TeslaMateWeb.ConnCase, async: false
  alias TeslaMate.{Accounts, Auth, Repo, TeslaFleet}
  alias TeslaMate.TeslaFleet.Connection
  @cookie "_teslamate_fleet_oauth"
  @config %{
    "client_id" => "test-client",
    "client_secret" => "test-secret",
    "region" => "cn",
    "origin" => "https://dashboard.example.com"
  }
  @vin "LRW3E7EK9MC123456"

  setup do
    start_supervised!(TeslaMate.Vault)
    previous_config = Application.get_env(:teslamate, :tesla_fleet_config)
    previous_http = Application.get_env(:teslamate, :tesla_fleet_http)
    Application.put_env(:teslamate, :tesla_fleet_config, @config)

    Application.put_env(:teslamate, :tesla_fleet_http, fn
      :post, "https://auth.tesla.cn/oauth2/v3/token", _, body ->
        data = URI.decode_query(body)
        assert data["client_id"] == "test-client"

        {:ok,
         %{
           "access_token" => "fleet-access",
           "refresh_token" => "fleet-refresh",
           "expires_in" => 3600
         }}

      :get, "https://fleet-api.prd.cn.vn.cloud.tesla.cn/api/1/vehicles", _, _ ->
        {:ok, %{"response" => [%{"vin" => @vin, "id" => 123, "vehicle_id" => 456}]}}
    end)

    on_exit(fn ->
      if previous_config,
        do: Application.put_env(:teslamate, :tesla_fleet_config, previous_config),
        else: Application.delete_env(:teslamate, :tesla_fleet_config)

      if previous_http,
        do: Application.put_env(:teslamate, :tesla_fleet_http, previous_http),
        else: Application.delete_env(:teslamate, :tesla_fleet_http)
    end)

    :ok
  end

  @tag platform_role: :member
  test "members use their own official page while admin aliases remain protected", %{conn: conn} do
    assert get(conn, "/admin/tesla-account/fleet").status == 404
    assert get(conn, "/tesla-account").status == 200
    assert get(conn, "/auth/tesla/start").status == 302
    assert post(conn, "/admin/tesla-account/fleet/check", %{vin: @vin}).status == 404

    assert post(conn, "/admin/tesla-account/fleet/configure", %{vin: @vin, interval: "10"}).status ==
             404
  end

  @tag auth: false
  test "anonymous users cannot initiate authorization", %{conn: conn} do
    assert redirected_to(get(conn, "/auth/tesla/start")) == "/sign_in"

    assert redirected_to(get(conn, "/auth/tesla/callback?code=test&state=invalid")) ==
             "/tesla-account"

    assert TeslaFleet.connection() == nil
  end

  test "official redirect requests only read scopes and sets a narrow encrypted callback cookie",
       %{conn: conn} do
    conn = get(conn, "/auth/tesla/start")
    uri = URI.parse(redirected_to(conn))
    q = URI.decode_query(uri.query)
    assert uri.host == "auth.tesla.cn"
    assert q["redirect_uri"] == "https://dashboard.example.com/auth/tesla/callback"
    assert q["scope"] == "openid offline_access vehicle_device_data vehicle_location"
    cookie = conn.resp_cookies[@cookie]
    assert cookie.same_site == "Lax"
    assert cookie.http_only
    assert cookie.path == "/auth/tesla"
    refute cookie.value =~ q["state"]
  end

  test "cross-site callback works without the Strict login cookie and preserves legacy tokens", %{
    conn: conn
  } do
    :ok = Auth.save(%{token: "legacy-access", refresh_token: "legacy-refresh"})
    started = get(conn, "/auth/tesla/start")

    state =
      started
      |> redirected_to()
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    cookie = started.resp_cookies[@cookie].value

    callback =
      build_conn()
      |> put_req_header("cookie", @cookie <> "=" <> cookie)
      |> get("/auth/tesla/callback", %{"code" => "one-time-code", "state" => state})

    html = html_response(callback, 200)
    assert html =~ "官网授权已完成"
    assert html =~ "1;url=/tesla-account"
    assert get_resp_header(callback, "location") == []
    assert get_session(callback, :user_session_token) == get_session(conn, :user_session_token)
    assert callback |> recycle() |> get("/tesla-account") |> html_response(200)
    assert TeslaFleet.connection().access == "fleet-access"
    assert Auth.get_tokens().access == "legacy-access"
    assert Repo.query!("SELECT access FROM private.fleet_connections").rows != [["fleet-access"]]

    replay =
      build_conn()
      |> put_req_header("cookie", @cookie <> "=" <> cookie)
      |> get("/auth/tesla/callback", %{"code" => "one-time-code", "state" => state})

    assert Phoenix.Flash.get(replay.assigns.flash, :error) =~ "授权会话"
  end

  test "state is bound to the initiating session and can only be consumed once", %{
    conn: conn,
    current_user: user
  } do
    token = get_session(conn, :user_session_token)
    {:ok, _, state} = TeslaFleet.start_authorization(token)
    {:ok, another} = Accounts.create_session(user)
    assert {:error, :invalid_state} = TeslaFleet.consume_state(state, state, another)
    assert {:ok, _} = TeslaFleet.consume_state(state, state, token)
    assert {:error, :invalid_state} = TeslaFleet.consume_state(state, state, token)
  end

  @tag platform_role: :member
  test "disabled users cannot finish an already started authorization", %{
    conn: conn,
    current_user: user
  } do
    token = get_session(conn, :user_session_token)
    {:ok, _, state} = TeslaFleet.start_authorization(token)
    user |> Ecto.Changeset.change(status: :disabled) |> Repo.update!()
    assert {:error, :invalid_state} = TeslaFleet.consume_state(state, state, token)
  end

  test "refresh rotation is saved and a second caller reuses the fresh token", %{
    current_user: user
  } do
    Repo.insert!(%Connection{
      id: 1,
      access: "expired",
      refresh: "old-refresh",
      authorized_by_id: user.id,
      expires_at: DateTime.add(DateTime.utc_now(), -1)
    })

    assert {:ok, "fleet-access"} = TeslaFleet.with_token(&{:ok, &1})

    Application.put_env(:teslamate, :tesla_fleet_http, fn _, _, _, _ ->
      flunk("unnecessary second refresh")
    end)

    assert {:ok, "fleet-access"} = TeslaFleet.with_token(&{:ok, &1})
    assert TeslaFleet.connection().refresh == "fleet-refresh"
  end

  test "failed OAuth exchange leaves both existing connections intact", %{current_user: user} do
    :ok = Auth.save(%{token: "legacy-access", refresh_token: "legacy-refresh"})

    Repo.insert!(%Connection{
      id: 1,
      authorized_by_id: user.id,
      access: "existing-fleet",
      refresh: "existing-refresh",
      expires_at: DateTime.add(DateTime.utc_now(), 3600)
    })

    Application.put_env(:teslamate, :tesla_fleet_http, fn _, _, _, _ ->
      {:error, :network_error}
    end)

    assert {:error, :network_error} = TeslaFleet.connect("bad-code", user)
    assert TeslaFleet.connection().access == "existing-fleet"
    assert Auth.get_tokens().access == "legacy-access"
  end

  test "admin integration page renders before and after authorization without exposing credentials",
       %{conn: conn, current_user: user} do
    html = conn |> get("/tesla-account") |> html_response(200)
    assert html =~ "Tesla 连接"
    assert html =~ "/auth/tesla/start"
    refute html =~ "test-secret"
    id = System.unique_integer([:positive])
    {:ok, car} = TeslaMate.Log.create_car(%{eid: id, vid: id, vin: @vin, model: "3"})

    assert {:ok, _} = Accounts.grant_car(user, user, car.id)

    Repo.insert!(%Connection{
      id: 1,
      authorized_by_id: user.id,
      access: "private-fleet-token",
      refresh: "private-refresh",
      expires_at: DateTime.add(DateTime.utc_now(), 3600),
      vehicles: %{@vin => %{}}
    })

    html = conn |> get("/tesla-account") |> html_response(200)
    assert html =~ "fleet-interval-#{car.id}"
    assert html =~ "/tesla-account/configure"
    refute html =~ "private-fleet-token"
    refute html =~ "private-refresh"
  end

  test "an unpaired vehicle with a synced empty configuration is not reported as enabled" do
    result = %{
      "configuration" => %{"config" => nil, "key_paired" => false, "synced" => true},
      "status" => %{
        "unpaired_vins" => [@vin],
        "key_paired_vins" => [],
        "vehicle_info" => %{
          @vin => %{"firmware_version" => "2026.8.300", "fleet_telemetry_version" => "1.2.0"}
        }
      }
    }

    assert TeslaMateWeb.TeslaFleetView.result_message(result) =~ "尚未确认数据钥匙"

    assert [%{firmware: "2026.8.300", paired?: false}] =
             TeslaMateWeb.TeslaFleetView.vehicle_status(result)

    assert TeslaMateWeb.TeslaFleetView.result_message(%{
             "configuration" => %{"config" => nil, "key_paired" => true, "synced" => true}
           }) =~ "尚未启用"
  end

  test "configuring telemetry checks owned vehicle capabilities before requesting new signals", %{
    current_user: user
  } do
    assert {:ok, _} = TeslaFleet.connect("authorization-code", user)

    Application.put_env(
      :teslamate,
      :tesla_fleet_config,
      Map.merge(@config, %{
        "telemetry_host" => "telemetry.example.com",
        "telemetry_port" => 8444,
        "telemetry_ca" => "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----",
        "proxy_url" => "https://fleet-proxy:4443"
      })
    )

    Application.put_env(:teslamate, :tesla_fleet_http, fn
      :post, "https://fleet-api.prd.cn.vn.cloud.tesla.cn/api/1/vehicles/fleet_status", _, body ->
        assert Jason.decode!(body)["vins"] == [@vin]

        {:ok,
         %{
           "response" => %{
             "vehicle_info" => %{
               @vin => %{"firmware_version" => "2026.32.1", "fleet_telemetry_version" => "1.3.0"}
             }
           }
         }}

      :post, "https://fleet-proxy:4443/api/1/vehicles/fleet_telemetry_config", _, body ->
        config = Jason.decode!(body)
        assert config["vins"] == [@vin]
        assert config["config"]["fields"]["NominalFullPackEnergyKwh"]["interval_seconds"] == 10
        assert config["config"]["fields"]["EnergyRemaining"]["include_fields"] == ["Soc"]
        {:ok, %{"response" => %{"updated_vehicles" => 1}}}
    end)

    assert {:ok, _} = TeslaFleet.configure_vehicle(user, @vin, 5)

    Application.put_env(:teslamate, :tesla_fleet_http, fn
      :post, "https://fleet-api.prd.cn.vn.cloud.tesla.cn/api/1/vehicles/fleet_status", _, _ ->
        {:error, :network_error}
    end)

    assert {:error, :network_error} = TeslaFleet.configure_vehicle(user, @vin, 5)
  end
end
