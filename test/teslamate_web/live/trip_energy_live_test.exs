defmodule TeslaMateWeb.TripEnergyLiveTest do
  use TeslaMateWeb.ConnCase, async: false

  alias TeslaMate.{Fleet, Log, Repo, Settings}
  alias TeslaMate.Locations.Address
  alias TeslaMate.Log.Drive

  setup do
    Settings.get_global_settings!()
    |> Ecto.Changeset.change(preferred_range: :rated)
    |> Repo.update!()

    {:ok, car} =
      Log.create_car(%{
        efficiency: 0.153,
        eid: System.unique_integer([:positive]),
        vid: System.unique_integer([:positive]),
        vin: "ENERGY#{System.unique_integer([:positive])}",
        model: "3"
      })

    address =
      Repo.insert!(%Address{
        osm_id: System.unique_integer([:positive]),
        osm_type: "node",
        latitude: Decimal.new("30"),
        longitude: Decimal.new("100"),
        raw: %{},
        city: "测试区",
        display_name: "测试街道, 测试区, 测试市, 中国"
      })

    date = DateTime.utc_now() |> DateTime.add(-3600)

    drive =
      Repo.insert!(%Drive{
        car_id: car.id,
        start_date: date,
        end_date: DateTime.add(date, 900),
        start_address_id: address.id,
        end_address_id: address.id,
        distance: 5.0,
        duration_min: 15,
        start_rated_range_km: Decimal.new("300"),
        end_rated_range_km: Decimal.new("290")
      })

    %{car: car, drive: drive}
  end

  test "list, detail and homepage show consistent energy with detailed addresses", %{
    conn: conn,
    current_user: user,
    car: car,
    drive: drive
  } do
    {:ok, list, html} = live(conn, "/trips?car=#{car.id}")
    assert has_element?(list, "#trip-row-#{drive.id}", "306.0 Wh/km")
    assert has_element?(list, "#trip-row-#{drive.id}", "1.53 kWh")
    assert html =~ "测试市 · 测试区 · 测试街道"
    assert hd(Fleet.trips(user, car.id).destinations).label == "测试市 · 测试区 · 测试街道"

    {:ok, detail, _html} = live(conn, "/trips/#{drive.id}")
    assert has_element?(detail, "#trip-energy-summary", "306.0 Wh/km")
    assert has_element?(detail, "#trip-energy-summary", "1.53 kWh")
    assert render(detail) =~ "估算"

    {:ok, home, _html} = live(conn, "/")
    assert has_element?(home, ".activity-list", "1.53 kWh")
    assert has_element?(home, ".activity-list", "306.0 Wh/km")
  end

  test "missing range readings show unknown rather than fabricated zero energy", %{
    conn: conn,
    drive: drive
  } do
    drive |> Ecto.Changeset.change(end_rated_range_km: nil) |> Repo.update!()

    {:ok, view, _html} = live(conn, "/trips")
    assert has_element?(view, "#trip-row-#{drive.id} [data-label='平均能耗']", "—")
    assert has_element?(view, "#trip-row-#{drive.id} [data-label='净耗电量']", "—")
    refute has_element?(view, "#trip-row-#{drive.id}", "0.00 kWh")
  end

  test "a zero-distance trip keeps its energy but has no Wh/km value", %{
    conn: conn,
    drive: drive
  } do
    drive |> Ecto.Changeset.change(distance: 0.0) |> Repo.update!()

    {:ok, view, _html} = live(conn, "/trips")
    assert has_element?(view, "#trip-row-#{drive.id} [data-label='平均能耗']", "—")
    assert has_element?(view, "#trip-row-#{drive.id} [data-label='净耗电量']", "1.53 kWh")
  end

  @tag platform_role: :member
  test "members only see energy and addresses for vehicles granted to them", %{
    conn: conn,
    current_user: user,
    car: car,
    drive: drive
  } do
    {:ok, _binding} = TeslaMate.AccountFixtures.grant(user, car)
    member = user

    {:ok, other_car} =
      Log.create_car(%{
        eid: System.unique_integer([:positive]),
        vid: System.unique_integer([:positive]),
        vin: "OTHER#{System.unique_integer([:positive])}"
      })

    other_drive =
      Repo.insert!(%Drive{car_id: other_car.id, start_date: DateTime.utc_now()})

    {:ok, view, _html} = live(conn, "/trips?car=#{other_car.id}")
    assert has_element?(view, "#trip-row-#{drive.id}", "1.53 kWh")
    refute has_element?(view, "#trip-row-#{other_drive.id}")
    assert Fleet.trip(member, other_drive.id) == nil

    assert {:error, {:redirect, %{to: "/trips"}}} = live(conn, "/trips/#{other_drive.id}")
  end

  test "official boundaries agree across list, detail, home, driving and analysis", %{
    conn: conn,
    current_user: user,
    car: car,
    drive: drive
  } do
    alias TeslaMate.TeslaFleet.Energy
    Energy.record(car.id, "EnergyRemaining", 50.0, DateTime.add(drive.start_date, -125))
    Energy.record(car.id, "EnergyRemaining", 49.0, DateTime.add(drive.end_date, -66))

    for {url, selector} <- [
          {"/trips", "#trip-row-#{drive.id}"},
          {"/trips/#{drive.id}", "#trip-energy-summary"},
          {"/", ".activity-list"}
        ] do
      {:ok, view, _} = live(conn, url)
      assert has_element?(view, selector, "200.0 Wh/km")
      assert has_element?(view, selector, "1.00 kWh")
      assert render(view) =~ "电池包读数计算"
      refute render(view) =~ "平均能耗（估算）"
      refute render(view) =~ "净耗电量（估算）"
    end

    report = Fleet.driving(user, car.id)
    assert report.metrics.net_energy == 1.0
    assert report.metrics.consumption == 200
    assert report.metrics.energy_source == :fleet_battery
    analysis = Fleet.analysis(user, car.id)
    assert analysis.drive.consumption_wh_km == 200
    assert analysis.drive.official_count == 1
    assert analysis.drive.energy_count == 1
    {:ok, view, html} = live(conn, "/analysis")
    assert html =~ "全部按电池包读数计算"
    assert has_element?(view, ".metric-card", "1.00 kWh")
    refute html =~ "估算能耗"

    older = %{
      drive
      | id: nil,
        start_date: DateTime.add(drive.start_date, -86_400),
        end_date: DateTime.add(drive.end_date, -86_400)
    }

    Repo.insert!(older)
    {:ok, _, mixed} = live(conn, "/analysis")
    assert mixed =~ "1 程电池读数 · 1 程续航估算"
  end
end
