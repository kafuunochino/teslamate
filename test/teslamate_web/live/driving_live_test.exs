defmodule TeslaMateWeb.DrivingLiveTest do
  use TeslaMateWeb.ConnCase, async: false

  alias TeslaMate.{Log, Repo}
  alias TeslaMate.Log.{Drive, Position}
  alias TeslaMateWeb.DashboardLive.Driving

  setup do
    {:ok, car} =
      Log.create_car(%{
        efficiency: 0.153,
        eid: System.unique_integer([:positive]),
        vid: System.unique_integer([:positive]),
        vin: "DRIVE#{System.unique_integer([:positive])}",
        model: "3"
      })

    date = DateTime.utc_now() |> DateTime.add(-10)
    drive = Repo.insert!(%Drive{car_id: car.id, start_date: date})

    position =
      Repo.insert!(%Position{
        car_id: car.id, drive_id: drive.id, date: date,
        latitude: Decimal.new("30"), longitude: Decimal.new("100"),
        elevation: 900, power: 36, odometer: 1000.0,
        rated_battery_range_km: Decimal.new("300")
      })

    %{car: car, drive: drive, position: position}
  end

  @tag auth: false
  test "requires authentication", %{conn: conn} do
    assert conn |> get("/driving") |> redirected_to() == "/sign_in"
  end

  @tag platform_role: :member
  test "does not expose another user's requested car", %{conn: conn, car: car} do
    {:ok, view, html} = live(conn, "/driving?car=#{car.id}")
    assert html =~ "尚未绑定车辆"
    refute has_element?(view, "#drive-altitude")
  end

  test "defaults to five seconds and preserves selected refresh in the URL", %{conn: conn, car: car} do
    {:ok, view, _html} = live(conn, "/driving")
    assert has_element?(view, "#drive-refresh-interval option[value='5'][selected]")
    assert has_element?(view, "#drive-altitude strong", "900")

    view
    |> element("#drive-refresh-form")
    |> render_change(%{"refresh" => %{"seconds" => "10"}})

    assert_patch(view, "/driving?car=#{car.id}&refresh=10")
    assert has_element?(view, "#drive-refresh-interval option[value='10'][selected]")
    assert Driving.normalize_interval("-1") == 5
    assert Driving.normalize_interval("1000000") == 5
  end

  test "pausing rejects an old timer but manual refresh still works", %{conn: conn, car: car, drive: drive} do
    {:ok, view, _html} = live(conn, "/driving")
    old_token = :sys.get_state(view.pid).socket.assigns.refresh_token

    view |> element("#drive-refresh-form") |> render_change(%{"refresh" => %{"seconds" => "0"}})
    assert has_element?(view, "#drive-refresh-interval option[value='0'][selected]")

    Repo.insert!(%Position{
      car_id: car.id, drive_id: drive.id, date: DateTime.utc_now(),
      latitude: Decimal.new("30"), longitude: Decimal.new("100"),
      elevation: 950, power: 36, odometer: 1000.1
    })

    render_hook(view, "visibility", %{"visible" => true})
    send(view.pid, {:refresh, old_token})
    refute render(view) =~ ">950</strong>"
    assert has_element?(view, "#drive-altitude strong", "900")

    view |> element("#drive-refresh-now") |> render_click()
    assert has_element?(view, "#drive-altitude strong", "950")
  end

  test "refresh removes telemetry after access is revoked", %{conn: conn, current_user: user} do
    {:ok, view, _html} = live(conn, "/driving")
    assert has_element?(view, "#drive-altitude")

    user |> Ecto.Changeset.change(role: :member) |> Repo.update!()
    view |> element("#drive-refresh-now") |> render_click()

    refute has_element?(view, "#drive-altitude")
    assert render(view) =~ "尚未绑定车辆"
  end

  test "does not present saved power as instantaneous when the collector is absent", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/driving")
    assert has_element?(view, "#drive-instant-power", "—")
    assert render(view) =~ "最近记录"
  end
end
