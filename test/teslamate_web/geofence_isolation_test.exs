defmodule TeslaMateWeb.GeoFenceIsolationTest do
  use TeslaMateWeb.ConnCase, async: false
  alias TeslaMate.{Locations, Repo}
  alias TeslaMate.Accounts.User

  setup %{current_user: owner} do
    other = Repo.insert!(%User{email: "other-#{System.unique_integer([:positive])}@example.com",
      name: "Other User", role: :member, password_hash: "test-only", password_changed_at: DateTime.utc_now()})
    {:ok, own} = Locations.create_geofence(owner, %{name: "Own Place", latitude: 26.64, longitude: 106.63, radius: 100})
    {:ok, foreign} = Locations.create_geofence(other, %{name: "Secret Place", latitude: 36.64, longitude: 116.63, radius: 100})
    %{own: own, foreign: foreign, other: other}
  end

  @tag platform_role: :member
  test "member list and direct edit cannot expose another user's place", %{conn: conn, own: own, foreign: foreign} do
    {:ok, view, html} = live(conn, "/geo-fences")
    assert html =~ own.name
    refute html =~ foreign.name
    assert {:error, {:redirect, %{to: "/geo-fences"}}} = live(conn, "/geo-fences/#{foreign.id}/edit")
    render_click(view, "delete", %{"id" => foreign.id})
    assert Repo.get(TeslaMate.Locations.GeoFence, foreign.id)
  end

  @tag platform_role: :member
  test "new fence ignores a forged owner and does not initialize from other cars", %{conn: conn, current_user: user, other: other} do
    {:ok, view, html} = live(conn, "/geo-fences/new")
    assert html =~ ~s(data-latitude="0.0")
    render_submit(view, "save", %{"geo_fence" => %{
      "name" => "New own place", "latitude" => "26.64", "longitude" => "106.63",
      "radius" => "100", "user_id" => to_string(other.id)}})
    assert_redirect(view, "/geo-fences")
    fence = Repo.get_by!(TeslaMate.Locations.GeoFence, name: "New own place")
    assert fence.user_id == user.id
  end
end
