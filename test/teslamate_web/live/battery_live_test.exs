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
    refute has_element?(view, "#battery-charge_limit_soc")
    refute has_element?(view, "#battery-advanced")
    refute render(view) =~ "0.0 °C"
  end

  test "temperature panels use saved climate samples when newer streaming positions omit them", %{
    conn: conn,
    car: car,
    position: position
  } do
    position
    |> Ecto.Changeset.change(
      inside_temp: Decimal.new("-2.5"),
      outside_temp: Decimal.new("0"),
      driver_temp_setting: Decimal.new("21"),
      passenger_temp_setting: Decimal.new("22")
    )
    |> Repo.update!()

    Repo.insert!(%Position{
      car_id: car.id,
      date: DateTime.utc_now(),
      latitude: Decimal.new("30"),
      longitude: Decimal.new("100"),
      battery_level: 50,
      usable_battery_level: 49
    })

    {:ok, view, html} = live(conn, "/driving")
    assert has_element?(view, "#driving-climate", "座舱与空调")
    assert has_element?(view, "#driving-inside_temp dd", "-2.5 °C")
    assert has_element?(view, "#driving-outside_temp dd", "0.0 °C")
    assert has_element?(view, "#driving-inside_temp small", "最近记录")
    assert has_element?(view, "#driving-cabin_temp_delta dd", "-2.5 °C")
    for page <- ["battery", "charging"] do
      {:ok, other, _} = live(conn, "/#{page}")
      refute has_element?(other, "##{page}-inside_temp")
      refute has_element?(other, "##{page}-driver_temp_setting")
      refute has_element?(other, "##{page}-rear_motor_temp")
    end
    ids = html |> Floki.parse_document!() |> Floki.find("[id]") |> Floki.attribute("id")
    assert length(ids) == length(Enum.uniq(ids))

  end

  test "temperature telemetry is rendered with timestamps and removed on invalid refresh", %{
    conn: conn,
    car: car
  } do
    now = DateTime.utc_now()

    Repo.insert_all("fleet_readings", [
      %{
        car_id: car.id,
        field: "DiStatorTempR",
        data: %{"value" => 63.5, "invalid" => false},
        measured_at: now,
        received_at: now
      },
      %{
        car_id: car.id,
        field: "DiStatorTempREL",
        data: %{"value" => 0, "invalid" => false},
        measured_at: now,
        received_at: now
      }
    ])

    {:ok, view, _} = live(conn, "/driving")
    assert has_element?(view, "#driving-rear_motor_temp dd", "63.5 °C")
    assert has_element?(view, "#driving-rear_motor_temp small", "遥测")
    assert has_element?(view, "#driving-rear_left_motor_temp dd", "0.0 °C")
    refute has_element?(view, "#driving-rear_right_motor_temp")

    Repo.query!(
      "UPDATE fleet_readings SET data = $1::jsonb WHERE car_id = $2 AND field = $3",
      [%{"value" => nil, "invalid" => true}, car.id, "DiStatorTempR"]
    )

    view |> element("#drive-refresh-now") |> render_click()
    refute has_element?(view, "#driving-rear_motor_temp")
    view |> element("#driving-advanced-toggle") |> render_click()
    assert has_element?(view, "#driving-rear_motor_temp dd", "—")
    assert has_element?(view, "#driving-rear_motor_temp small", "车辆上报无效读数")
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
    view |> element("#charging-advanced-toggle") |> render_click()
    before = :sys.get_state(view.pid).socket.assigns.cost_changeset
    token = :sys.get_state(view.pid).socket.assigns.battery_token
    send(view.pid, {:battery_refresh, token})
    render(view)
    assert :sys.get_state(view.pid).socket.assigns.cost_changeset == before
    assert has_element?(view, "#charge-cost-form")
    assert has_element?(view, "#charging-charger_voltage dd", "220 V")
    assert has_element?(view, "#charging-charger_power dd", "0.0 kW")
    assert render(view) =~ "并非电池包电压"
  end

  test "unsaved cost input survives automatic and full refresh without changing the database", %{
    conn: conn,
    charge: charge
  } do
    {:ok, view, _} = live(conn, "/charging")
    original_cost = Repo.get!(ChargingProcess, charge.id).cost
    view |> element("#charge-cost-edit-#{charge.id}") |> render_click()
    view |> form("#charge-cost-form", charge_cost: %{cost: "23.04"}) |> render_change()

    token = :sys.get_state(view.pid).socket.assigns.battery_token
    send(view.pid, {:battery_refresh, token})
    assert has_element?(view, "#charge-cost-form input[name='charge_cost[cost]'][value='23.04']")
    view |> element("#battery-refresh-now") |> render_click()
    assert has_element?(view, "#charge-cost-form input[name='charge_cost[cost]'][value='23.04']")
    assert Repo.get!(ChargingProcess, charge.id).cost == original_cost

    view |> element("#charge-cost-form button", "取消") |> render_click()
    refute has_element?(view, "#charge-cost-form")
    assert Repo.get!(ChargingProcess, charge.id).cost == original_cost
  end

  test "charging details stay open across new samples and full refreshes", %{conn: conn, car: car} do
    {:ok, view, _} = live(conn, "/charging")
    refute has_element?(view, "#charging-advanced")
    view |> element("#charging-advanced-toggle") |> render_click()

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
    refute has_element?(view, "#charging-battery_level")
    assert has_element?(view, "#charging-advanced-toggle[aria-expanded=true]")
    assert has_element?(view, "#charging-advanced")
    view |> element("#battery-refresh-now") |> render_click()
    assert has_element?(view, "#charging-advanced")
    view |> element("#charging-advanced-toggle") |> render_click()
    refute has_element?(view, "#charging-advanced")
  end
  test "advanced sections preserve their state and current readings stay outside", %{conn: conn, car: car} do
    now = DateTime.utc_now()
    for {field, value} <- [{"ModuleTempMax", 35}, {"ModuleTempMin", 30},
                           {"DiStatorTempR", 60}, {"PackVoltage", 350}] do
      Repo.insert_all("fleet_readings", [%{car_id: car.id, field: field,
        data: %{"value" => value, "invalid" => false}, measured_at: now, received_at: now}])
    end

    for {page, refresh, visible} <- [{"battery", "#battery-refresh-now", "module_temp_max"},
                                    {"driving", "#drive-refresh-now", "rear_motor_temp"},
                                    {"charging", "#battery-refresh-now", "charger_voltage"}] do
      {:ok, view, _} = live(conn, "/#{page}")
      assert has_element?(view, "##{page}-#{visible}")
      refute has_element?(view, "##{page}-advanced")
      view |> element("##{page}-advanced-toggle") |> render_click()
      view |> element(refresh) |> render_click()
      assert has_element?(view, "##{page}-advanced-toggle[aria-expanded=true]")
      assert has_element?(view, "##{page}-advanced")
      refute has_element?(view, "##{page}-advanced ##{page}-#{visible}")
      ids = render(view) |> Floki.parse_document!() |> Floki.find("[id]") |> Floki.attribute("id")
      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  test "charging totals, day chart and stations use the same official values without rewriting history", %{
    current_user: user, car: car, charge: charge
  } do
    alias TeslaMate.TeslaFleet.Energy
    import Ecto.Query
    from(c in Charge, where: c.charging_process_id == ^charge.id)
    |> Repo.update_all(set: [fast_charger_present: false])

    for {field, value} <- [{"DCChargingEnergyIn", 19.0}, {"ACChargingEnergyIn", 21.0}] do
      Energy.record(car.id, field, 0.0, charge.start_date)
      Energy.record(car.id, field, value, charge.end_date)
    end

    report = TeslaMate.Fleet.charging(user, car.id)
    assert Decimal.equal?(report.stats.energy_added, 19)
    assert Decimal.equal?(report.stats.energy_used, 21)
    assert report.stats.loss_kwh == 2
    assert report.stats.loss_count == 1
    assert report.stats.official_count == 1
    assert hd(report.sessions).charge_energy_added == 19
    assert hd(report.daily_energy).value == 19
    assert hd(report.stations).energy == 19
    assert Decimal.equal?(TeslaMate.Fleet.home(user, car.id).charge_stats.energy_added, 19)
    assert Decimal.equal?(Repo.get!(ChargingProcess, charge.id).charge_energy_added, 20)
  end

end
