defmodule TeslaMate.MapsTest do
  use TeslaMate.DataCase

  alias TeslaMate.{Maps, Repo}
  alias TeslaMate.Accounts.User
  alias TeslaMate.Maps.{AmapProxy, Settings}

  @key String.duplicate("a", 32)
  @code String.duplicate("b", 32)

  setup do
    start_supervised!(TeslaMate.Vault)

    user =
      Repo.insert!(%User{
        email: "map-admin@example.com",
        name: "Map Admin",
        password_hash: "test-only",
        password_changed_at: DateTime.utc_now(),
        role: :admin,
        status: :active
      })

    %{user: user}
  end

  test "requires both credentials and leaves active settings unchanged on failure", %{user: user} do
    assert {:error, changeset} =
             Maps.update_settings(user, %{"provider" => "amap", "amap_key" => @key})

    assert changeset.errors[:amap_security_code]
    assert Maps.browser_config() == %{provider: "openstreetmap"}
    assert {:error, _} = Maps.update_settings(user, %{"provider" => "other"})
  end

  test "encrypts credentials, retains blanks and exposes only the browser key", %{user: user} do
    assert {:ok, _} =
             Maps.update_settings(user, %{
               "provider" => "amap",
               "amap_key" => @key,
               "amap_security_code" => @code
             })

    assert Maps.browser_config() == %{provider: "amap", key: @key, service_host: "/_AMapService"}

    assert {:ok, saved} =
             Maps.update_settings(user, %{
               "provider" => "amap",
               "amap_key" => "",
               "amap_security_code" => " "
             })

    assert saved.amap_security_code == @code
    refute inspect(saved) =~ @code

    result =
      Repo.query!("SELECT amap_key, amap_security_code FROM private.map_settings WHERE id = 1")

    [[key, code]] = result.rows
    refute key == @key
    refute code == @code
    refute Jason.encode!(Maps.preferences()) =~ @code

    assert {:ok, _} = Maps.update_settings(user, %{"provider" => "openstreetmap"})
    assert Maps.browser_config() == %{provider: "openstreetmap"}
    assert Maps.preferences().has_amap_key
  end

  test "rechecks current administrator status before writing", %{user: user} do
    Repo.update!(Ecto.Changeset.change(user, role: :member))
    assert {:error, :forbidden} = Maps.update_settings(user, %{"provider" => "openstreetmap"})
    assert {:error, :forbidden} = Maps.update_settings(nil, %{})
  end

  test "proxy restricts destinations and overrides untrusted credentials" do
    config = %Settings{provider: :amap, amap_key: @key, amap_security_code: @code}

    assert {:ok, url} =
             AmapProxy.upstream_url(
               config,
               ["v4", "map", "styles"],
               "key=attacker&jscode=attacker&callback=AMap.cb"
             )

    uri = URI.parse(url)
    assert uri.host == "webapi.amap.com"
    assert URI.decode_query(uri.query)["jscode"] == @code
    assert URI.decode_query(uri.query)["key"] == @key

    for path <- [["..", "maps"], ["v3", "direction", "driving"], ["https:", "", "evil.test"]] do
      assert {:error, :invalid_request} = AmapProxy.upstream_url(config, path, "")
    end

    assert {:error, :invalid_request} =
             AmapProxy.upstream_url(config, ["v4", "map", "styles"], "callback=alert(1)")
  end

  test "proxy permits geofence address lookup but blocks other web service APIs" do
    config = %Settings{provider: :amap, amap_key: @key, amap_security_code: @code}

    assert {:ok, url} =
             AmapProxy.upstream_url(config, ["v3", "geocode", "geo"], "address=Guiyang&key=untrusted")

    uri = URI.parse(url)
    assert uri.host == "restapi.amap.com"
    assert uri.path == "/v3/geocode/geo"
    assert URI.decode_query(uri.query)["address"] == "Guiyang"
    assert URI.decode_query(uri.query)["key"] == @key

    assert {:error, :invalid_request} =
             AmapProxy.upstream_url(config, ["v3", "place", "around"], "")
  end

  test "proxy handles failures without exposing upstream secrets" do
    config = %Settings{provider: :amap, amap_key: @key, amap_security_code: @code}

    request = fn _url, _opts ->
      {:ok,
       %Finch.Response{status: 200, headers: [{"content-type", "application/json"}], body: @code}}
    end

    assert {:ok, "application/json", "[REDACTED]"} =
             AmapProxy.request(config, ["v4", "map", "styles"], "", request)

    assert {:error, :upstream_unavailable} =
             AmapProxy.request(config, ["v4", "map", "styles"], "", fn _, _ ->
               {:error, :timeout}
             end)
  end

  test "proxy serves validated JSONP with a script MIME type under nosniff" do
    config = %Settings{provider: :amap, amap_key: @key, amap_security_code: @code}

    for headers <- [
          [{"content-type", "application/json"}],
          [{"Content-Type", "application/octet-stream"}],
          []
        ] do
      request = fn _, _ ->
        {:ok,
         %Finch.Response{status: 200, headers: headers, body: "AMap.cb({\"status\":\"1\"});"}}
      end

      assert {:ok, "application/javascript; charset=utf-8", "AMap.cb({\"status\":\"1\"});"} =
               AmapProxy.request(config, ["v3", "log", "init"], "callback=AMap.cb", request)
    end
  end

  test "proxy does not turn mismatched callbacks or executable payloads into scripts" do
    config = %Settings{provider: :amap, amap_key: @key, amap_security_code: @code}

    for body <- [
          "another_callback({});",
          "AMap.cb({});alert(1);",
          "AMap.cb(alert(1));",
          "<html>upstream error</html>"
        ] do
      request = fn _, _ ->
        {:ok, %Finch.Response{status: 200, headers: [], body: body}}
      end

      assert {:error, :upstream_unavailable} =
               AmapProxy.request(config, ["v3", "log", "init"], "callback=AMap.cb", request)
    end
  end

  test "proxy keeps non-JSONP responses and handles case-insensitive MIME headers" do
    config = %Settings{provider: :amap, amap_key: @key, amap_security_code: @code}

    request = fn _, _ ->
      {:ok,
       %Finch.Response{status: 200, headers: [{"Content-Type", "application/json"}], body: "{}"}}
    end

    assert {:ok, "application/json", "{}"} =
             AmapProxy.request(config, ["v4", "map", "styles"], "", request)
  end
end
