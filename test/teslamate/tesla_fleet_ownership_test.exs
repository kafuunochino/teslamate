defmodule TeslaMate.TeslaFleetOwnershipTest do
  use TeslaMate.DataCase, async: false
  alias TeslaMate.{Accounts, Repo, TeslaFleet}
  alias TeslaMate.Accounts.{User, UserCar}
  alias TeslaMate.TeslaFleet.{Connection, Readings}
  @vin1 "LRW3E7EK9MC123456"
  @vin2 "LRW3E7EK9MC654321"

  setup do
    start_supervised!(TeslaMate.Vault)
    TeslaMate.AccountFixtures.system_admin()
    previous_config = Application.get_env(:teslamate, :tesla_fleet_config)
    previous_http = Application.get_env(:teslamate, :tesla_fleet_http)

    Application.put_env(:teslamate, :tesla_fleet_config, %{
      "client_id" => "test",
      "client_secret" => "test-secret",
      "region" => "cn",
      "origin" => "https://dashboard.example.com"
    })

    [first, second] =
      for n <- [1, 2] do
        Repo.insert!(%User{
          email: "fleet#{n}-#{System.unique_integer([:positive])}@example.com",
          name: "Member #{n}",
          password_hash: "test-only",
          password_changed_at: DateTime.utc_now()
        })
      end

    on_exit(fn ->
      if previous_config,
        do: Application.put_env(:teslamate, :tesla_fleet_config, previous_config),
        else: Application.delete_env(:teslamate, :tesla_fleet_config)

      if previous_http,
        do: Application.put_env(:teslamate, :tesla_fleet_http, previous_http),
        else: Application.delete_env(:teslamate, :tesla_fleet_http)
    end)

    %{first: first, second: second}
  end

  defp response(vin, id, token) do
    Application.put_env(:teslamate, :tesla_fleet_http, fn
      :post, "https://auth.tesla.cn/oauth2/v3/token", _, _ ->
        {:ok,
         %{"access_token" => token, "refresh_token" => token <> "-refresh", "expires_in" => 3600}}

      :get, "https://fleet-api.prd.cn.vn.cloud.tesla.cn/api/1/vehicles", _, _ ->
        {:ok,
         %{
           "response" => [
             %{"vin" => vin, "id" => id, "vehicle_id" => id + 1, "display_name" => "Own car"}
           ]
         }}
    end)
  end

  test "two users get isolated encrypted tokens and exclusive vehicles", %{
    first: first,
    second: second
  } do
    response(@vin1, 100, "first-access")
    assert {:ok, _} = TeslaFleet.connect("code1", first)
    response(@vin2, 200, "second-access")
    assert {:ok, _} = TeslaFleet.connect("code2", second)
    assert TeslaFleet.connection(first).access == "first-access"
    assert TeslaFleet.connection(second).access == "second-access"
    assert Repo.aggregate(Connection, :count) == 2
    assert Enum.map(Accounts.list_accessible_cars(first), & &1.vin) == [@vin1]
    assert Enum.map(Accounts.list_accessible_cars(second), & &1.vin) == [@vin2]
    refute inspect(TeslaFleet.connection(first)) =~ "first-access"
    assert :ok = TeslaFleet.known_vehicle(first, @vin1)
    assert {:error, :unknown_vehicle} = TeslaFleet.known_vehicle(first, @vin2)
  end

  test "OAuth cannot overwrite a different user's ownership or tokens", %{
    first: first,
    second: second
  } do
    response(@vin1, 100, "first-access")
    assert {:ok, _} = TeslaFleet.connect("code1", first)
    response(@vin1, 100, "second-access")
    assert {:error, :vehicle_already_bound} = TeslaFleet.connect("code2", second)
    assert TeslaFleet.connection(second) == nil
    assert TeslaFleet.connection(first).access == "first-access"
    assert Repo.one!(UserCar).user_id == first.id
  end

  test "forged VIN cannot reach Tesla using another user's authorization", %{
    first: first,
    second: second
  } do
    response(@vin1, 100, "first-access")
    assert {:ok, _} = TeslaFleet.connect("code1", first)

    Application.put_env(:teslamate, :tesla_fleet_http, fn _, _, _, _ ->
      flunk("unauthorized network request")
    end)

    assert {:error, :not_connected} = TeslaFleet.check_vehicle(second, @vin1)
    assert {:error, :not_connected} = TeslaFleet.configure_vehicle(second, @vin1, 10)
    assert {:error, :unknown_vehicle} = TeslaFleet.check_vehicle(first, @vin2)
  end

  test "revocation during OAuth exchange cannot resurrect the session or save tokens", %{
    first: first
  } do
    {:ok, token} = Accounts.create_session(first)

    Application.put_env(:teslamate, :tesla_fleet_http, fn
      :post, _, _, _ ->
        Accounts.delete_session(token)

        {:ok,
         %{
           "access_token" => "race-access",
           "refresh_token" => "race-refresh",
           "expires_in" => 3600
         }}

      :get, _, _, _ ->
        {:ok, %{"response" => []}}
    end)

    assert {:error, :invalid_state} = TeslaFleet.connect("code", first, token)
    assert TeslaFleet.connection(first) == nil
  end

  test "receiver rejects a VIN after ownership or account access is revoked", %{first: first} do
    response(@vin1, 100, "first-access")
    assert {:ok, _} = TeslaFleet.connect("code", first)
    assert :ok = TeslaFleet.known_vehicle(@vin1)
    Repo.delete_all(from b in UserCar, where: b.user_id == ^first.id)
    assert {:error, :unknown_vehicle} = TeslaFleet.known_vehicle(@vin1)

    payload =
      Jason.encode!(%{"value" => 350, "created_at" => DateTime.to_iso8601(DateTime.utc_now())})

    assert :ignored = Readings.ingest(@vin1, "PackVoltage", payload)
  end

  test "disconnect removes only the caller's official binding and connection", %{
    first: first,
    second: second
  } do
    response(@vin1, 100, "first-access")
    assert {:ok, _} = TeslaFleet.connect("code1", first)
    response(@vin2, 200, "second-access")
    assert {:ok, _} = TeslaFleet.connect("code2", second)
    assert {:ok, :ok} = TeslaFleet.disconnect(first)
    assert TeslaFleet.connection(first) == nil
    assert TeslaFleet.connection(second).access == "second-access"
    assert Accounts.list_accessible_cars(first) == []
    assert length(Accounts.list_accessible_cars(second)) == 1
    assert Repo.aggregate(TeslaMate.Log.Car, :count) == 2
  end

  test "new fleet cars use their owner's token for collection and cannot fall back to legacy credentials",
       %{first: first} do
    response(@vin1, 100, "first-access")
    assert {:ok, _} = TeslaFleet.connect("code1", first)
    [car] = Accounts.list_accessible_cars(first)
    assert TeslaFleet.fleet_collector?(car.eid)
    assert Repo.preload(car, :settings).settings.use_streaming_api == false

    Application.put_env(:teslamate, :tesla_fleet_http, fn :get, url, headers, _ ->
      assert url == "https://fleet-api.prd.cn.vn.cloud.tesla.cn/api/1/vehicles/" <> @vin1
      assert {"authorization", "Bearer first-access"} in headers

      {:ok,
       %{"response" => %{"vin" => @vin1, "id" => 100, "vehicle_id" => 101, "state" => "asleep"}}}
    end)

    assert {:ok, %TeslaApi.Vehicle{vin: @vin1}} = TeslaFleet.collector_vehicle(car.eid, false)
    assert {:ok, :ok} = TeslaFleet.disconnect(first)
    assert TeslaFleet.fleet_collector?(car.eid)
    assert {:error, :not_signed_in} = TeslaFleet.collector_vehicle(car.eid, false)
  end
end
