defmodule TeslaMateWeb.BatteryLiveTest do
  use TeslaMateWeb.ConnCase, async: false

  alias TeslaMate.{Log, Repo}
  alias TeslaMate.Log.{Charge, ChargingProcess, Position}

  setup do
    id = System.unique_integer([:positive])
    {:ok, car} = Log.create_car(%{eid: id, vid: id, vin: "BATTERY#{id}", model: "3"})
    date = DateTime.add(DateTime.utc_now(), -120)

    position =
      Repo.insert!(%Position{
        car_id: car.id,
        date: date,
        latitude: Decimal.new("30"),
        longitude: Decimal.new("100"),
        battery_level: 51,
        usable_battery_level: 50,
        battery_heater_on: false,
        rated_battery_range_km: Decimal.new("210")
      })

    process =
      Repo.insert!(%ChargingProcess{
        car_id: car.id,
        position_id: position.id,
        start_date: DateTime.add(date, -3600),
        end_date: date,
        charge_energy_added: Decimal.new("20"),
        charge_energy_used: Decimal.new("22"),
        duration_min: 60
      })

    Repo.insert!(%Charge{
      charging_process_id: process.id,
      date: date,
      battery_level: 51,
      usable_battery_level: 50,
      charger_voltage: 220,
      charger_power: 0,
      charge_energy_added: Decimal.new("20"),
      ideal_battery_range_km: Decimal.new("210"),
      battery_heater_on: false
    })

    %{car: car, position: position, charge: process}
  end

  @tag auth: false
  test "battery requires sign-in", %{conn: conn} do
    assert conn |> get("/battery") |> redirected_to() == "/sign_in"
  end

  @tag platform_role: :member
  test "all three pages exclude another user's battery readings", %{conn: conn, car: car} do
    for page <- ["battery", "charging", "driving"] do
      {:ok, view, html} = live(conn, "/#{page}?car=#{car.id}")
      assert html =~ "尚未绑定车辆"
      refute has_element?(view, "##{page}-readings")
    end
  end

  test "shows saved readings after restart with unknown fields left empty", %{conn: conn} do
    {:ok, view, _} = live(conn, "/battery")
    assert has_element?(view, "#battery-usable_battery_level dd", "50.0%")
    assert has_element?(view, "#battery-battery_heater_on dd", "关闭")
    assert has_element?(view, "#battery-battery_heater_on small", "最近记录")
    assert has_element?(view, "#battery-unavailable_level dd", "1.0 个百分点")
    assert has_element?(view, "#battery-charge_limit_soc dd", "—")
    refute render(view) =~ "0.0 °C"
  end

  test "refresh updates samples, keeps the selected range and rejects a hidden-tab timer", %{
    conn: conn,
    car: car,
    position: position
  } do
    {:ok, view, _} = live(conn, "/battery?car=#{car.id}&days=7")
    token = :sys.get_state(view.pid).socket.assigns.battery_token
    render_hook(view, "visibility", %{"visible" => false})

    position |> Ecto.Changeset.change(usable_battery_level: 49) |> Repo.update!()
    send(view.pid, {:battery_refresh, token})
    assert has_element?(view, "#battery-usable_battery_level dd", "50.0%")

    # A later position must win over the old charge sample.
    Repo.insert!(%Position{
      car_id: car.id,
      date: DateTime.utc_now(),
      latitude: Decimal.new("30"),
      longitude: Decimal.new("100"),
      battery_level: 50,
      usable_battery_level: 49
    })

    view |> element("#battery-refresh-now") |> render_click()
    assert has_element?(view, "#battery-usable_battery_level dd", "49.0%")
    assert has_element?(view, ".range-picker button.is-active", "7 天")
  end

  test "refresh clears battery and charge editing after access revocation", %{
    conn: conn,
    current_user: user,
    charge: charge
  } do
    {:ok, battery, _} = live(conn, "/battery")
    {:ok, charging, _} = live(conn, "/charging")
    charging |> element("#charge-cost-edit-#{charge.id}") |> render_click()

    user |> Ecto.Changeset.change(role: :member) |> Repo.update!()

    for view <- [battery, charging] do
      view |> element("#battery-refresh-now") |> render_click()
      assert render(view) =~ "尚未绑定车辆"
      refute has_element?(view, ".battery-readings")
    end

    refute has_element?(charging, "#charge-cost-form")
  end

  test "background charge refresh keeps cost form and validation errors", %{
    conn: conn,
    charge: charge
  } do
    {:ok, view, _} = live(conn, "/charging")
    view |> element("#charge-cost-edit-#{charge.id}") |> render_click()
    view |> form("#charge-cost-form", charge_cost: %{cost: "0.001"}) |> render_submit()
    view |> element("#battery-details-toggle") |> render_click()
    before = :sys.get_state(view.pid).socket.assigns.cost_changeset
    token = :sys.get_state(view.pid).socket.assigns.battery_token
    send(view.pid, {:battery_refresh, token})
    render(view)
    assert :sys.get_state(view.pid).socket.assigns.cost_changeset == before
    assert has_element?(view, "#charge-cost-form")
    assert has_element?(view, "#charging-extra-charger_voltage dd", "220 V")
    assert has_element?(view, "#charging-charger_power dd", "0.0 kW")
    assert render(view) =~ "并非电池包电压"
  end

  test "charging details stay open across new samples and full refreshes", %{conn: conn, car: car} do
    {:ok, view, _} = live(conn, "/charging")
    refute has_element?(view, "#battery-charging-details")
    view |> element("#battery-details-toggle") |> render_click()

    Repo.insert!(%Position{
      car_id: car.id,
      date: DateTime.utc_now(),
      latitude: Decimal.new("30"),
      longitude: Decimal.new("100"),
      battery_level: 52,
      usable_battery_level: 51
    })

    token = :sys.get_state(view.pid).socket.assigns.battery_token
    send(view.pid, {:battery_refresh, token})
    assert has_element?(view, "#charging-battery_level dd", "52.0%")
    assert has_element?(view, "#battery-details-toggle[aria-expanded=true]")
    assert has_element?(view, "#battery-charging-details")
    view |> element("#battery-refresh-now") |> render_click()
    assert has_element?(view, "#battery-charging-details")
    view |> element("#battery-details-toggle") |> render_click()
    refute has_element?(view, "#battery-charging-details")
  end
end
