defmodule TeslaMateWeb.MapSettingsTest do
  use TeslaMateWeb.ConnCase

  alias TeslaMate.Maps

  setup do
    start_supervised!(TeslaMate.Vault)
    :ok
  end

  test "shows provider-specific fields without applying drafts", %{conn: conn} do
    assert {:ok, view, _} = live(conn, "/admin/settings")
    refute has_element?(view, "#amap-credentials")
    view |> form("#map-settings-form", map_settings: %{provider: "amap"}) |> render_change()
    assert has_element?(view, "#amap-credentials")
    assert Maps.browser_config() == %{provider: "openstreetmap"}

    view
    |> form("#map-settings-form",
      map_settings: %{provider: "amap", amap_key: "", amap_security_code: ""}
    )
    |> render_submit()

    assert render(view) =~ "启用高德地图前请填写此项"
    assert Maps.browser_config() == %{provider: "openstreetmap"}
  end

  test "applies only on submit and never renders saved secrets", %{conn: conn} do
    key = String.duplicate("a", 32)
    code = String.duplicate("b", 32)
    assert {:ok, view, _} = live(conn, "/admin/settings")
    render_change(view, "map_draft", %{"map_settings" => %{"provider" => "amap"}})

    view
    |> form("#map-settings-form",
      map_settings: %{provider: "amap", amap_key: key, amap_security_code: code}
    )
    |> render_submit()

    assert_redirect(view, "/admin/settings")
    assert Maps.browser_config().provider == "amap"
    assert {:ok, _view, html} = live(conn, "/admin/settings")
    assert html =~ "已保存，留空保留"
    refute html =~ key
    refute html =~ code
  end

  test "retains newly typed credentials while editing and after a failed submit", %{conn: conn} do
    key = String.duplicate("c", 32)
    assert {:ok, view, _} = live(conn, "/admin/settings")

    render_change(view, "map_draft", %{
      "map_settings" => %{"provider" => "amap", "amap_key" => key, "amap_security_code" => ""}
    })

    assert has_element?(view, "#map_settings_amap_key[value='#{key}']")
    render_submit(view, "save_map_settings", %{
      "map_settings" => %{"provider" => "amap", "amap_key" => key, "amap_security_code" => ""}
    })

    assert has_element?(view, "#map_settings_amap_key[value='#{key}']")
    assert Maps.browser_config() == %{provider: "openstreetmap"}
  end

  @tag platform_role: :member
  test "members cannot open map settings", %{conn: conn} do
    assert conn |> get("/admin/settings") |> response(404)
  end
end
