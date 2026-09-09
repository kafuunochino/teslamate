defmodule TeslaMateWeb.FleetTimezoneTest do
  use TeslaMateWeb.ConnCase, async: false

  alias TeslaMate.{Fleet, Log, Repo}
  alias TeslaMate.Log.{ChargingProcess, Drive, Position}

  setup do
    {:ok, car} =
      Log.create_car(%{
        efficiency: 0.153,
        eid: System.unique_integer([:positive]),
        vid: System.unique_integer([:positive]),
        vin: "TIME#{System.unique_integer([:positive])}",
        model: "3"
      })

    %{car: car}
  end

  test "groups trips, charging and battery samples by Beijing day and month", %{
    current_user: user,
    car: car
  } do
    day = Date.utc_today() |> Date.beginning_of_month() |> Date.add(-1)
    following_day = Date.add(day, 1)

    for {time, amount} <- [{~T[15:50:00.000000], 1}, {~T[16:10:00.000000], 2}] do
      date = DateTime.new!(day, time, "Etc/UTC")

      Repo.insert!(%Drive{
        car_id: car.id,
        start_date: date,
        end_date: DateTime.add(date, 60),
        distance: amount * 1.0,
        duration_min: 1
      })

      position =
        Repo.insert!(%Position{
          car_id: car.id,
          date: date,
          latitude: Decimal.new("30"),
          longitude: Decimal.new("100"),
          battery_level: 50,
          rated_battery_range_km: Decimal.new(300 + amount * 10)
        })

      Repo.insert!(%ChargingProcess{
        car_id: car.id,
        position_id: position.id,
        start_date: date,
        charge_energy_added: Decimal.new(amount * 10)
      })
    end

    trips = Fleet.trips(user, car.id, 365)
    charging = Fleet.charging(user, car.id, 365)
    battery = Fleet.battery(user, car.id, 365)
    analysis = Fleet.analysis(user, car.id, 365)

    assert Enum.map(trips.daily_distance, & &1.period) == [day, following_day]
    assert Enum.map(trips.daily_distance, & &1.value) == [1.0, 2.0]
    assert Enum.map(charging.daily_energy, & &1.period) == [day, following_day]
    assert Enum.map(charging.daily_energy, &Decimal.to_integer(&1.value)) == [10, 20]
    assert Enum.map(battery.history, & &1.period) == [day, following_day]

    assert Enum.map(analysis.monthly_distance, & &1.period) ==
             [Date.beginning_of_month(day), following_day]
  end

  test "classifies night, weekend and active days using Beijing time", %{
    current_user: user,
    car: car
  } do
    friday = Date.utc_today() |> Date.beginning_of_week() |> Date.add(-3)
    saturday = Date.add(friday, 1)

    for {day, time} <- [
          {friday, ~T[13:30:00.000000]},
          {friday, ~T[16:30:00.000000]},
          {saturday, ~T[21:30:00.000000]}
        ] do
      date = DateTime.new!(day, time, "Etc/UTC")

      Repo.insert!(%Drive{
        car_id: car.id,
        start_date: date,
        end_date: DateTime.add(date, 60),
        distance: 5.0,
        duration_min: 1
      })
    end

    report = Fleet.analysis(user, car.id, 365)
    assert report.drive.active_days == 3
    assert_in_delta Decimal.to_float(report.drive.night_trip_ratio), 2 / 3, 0.000001
    assert_in_delta Decimal.to_float(report.drive.weekend_ratio), 2 / 3, 0.000001
  end
end
