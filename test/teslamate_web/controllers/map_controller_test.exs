defmodule TeslaMateWeb.MapControllerTest do
  use TeslaMateWeb.ConnCase

  alias TeslaMate.Maps

  @tag auth: false
  test "map configuration and proxy require authentication", %{conn: conn} do
    assert conn |> get("/maps/config") |> json_response(401)
    assert conn |> get("/_AMapService/v4/map/styles") |> json_response(401)
  end

  @tag platform_role: :member
  test "members can read the selected provider but a disabled proxy cannot be used", %{conn: conn} do
    assert conn |> get("/maps/config") |> json_response(200) == %{"provider" => "openstreetmap"}
    assert conn |> get("/_AMapService/v4/map/styles") |> json_response(404)
  end

  test "browser config excludes the security code and applies CSP for the saved provider", %{
    conn: conn,
    current_user: user
  } do
    start_supervised!(TeslaMate.Vault)
    key = String.duplicate("a", 32)
    code = String.duplicate("b", 32)

    assert {:ok, _} =
             Maps.update_settings(user, %{
               "provider" => "amap",
               "amap_key" => key,
               "amap_security_code" => code
             })

    response = get(conn, "/maps/config")
    assert get_resp_header(response, "cache-control") == ["private, no-store"]

    assert json_response(response, 200) == %{
             "provider" => "amap",
             "key" => key,
             "service_host" => "/_AMapService"
           }

    refute response.resp_body =~ code
    page = get(conn, "/admin/settings")
    [policy] = get_resp_header(page, "content-security-policy")
    assert policy =~ "https://webapi.amap.com"
    assert policy =~ "worker-src 'self' blob:"
    refute page.resp_body =~ code
    refute inspect(get_session(page)) =~ code
  end
end
