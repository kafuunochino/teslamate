defmodule TeslaMate.TeslaFleet.EnergyTest do
  use TeslaMate.DataCase, async: false
  alias TeslaMate.{Log, TripEnergy}
  alias TeslaMate.TeslaFleet.Energy

  setup do
    id = System.unique_integer([:positive])
    {:ok, car} = Log.create_car(%{eid: id, vid: id, vin: "ENERGYHISTORY#{id}"})
    start = DateTime.add(DateTime.utc_now(), -7200)
    interval = %{id: id, car_id: car.id, start_date: start, end_date: DateTime.add(start, 600),
      distance: 20.0, charge_energy_added: Decimal.new("9"), charge_energy_used: Decimal.new("12"),
      fast_charger: false}
    %{car: car, interval: interval}
  end

  defp sample(interval, field, offset, value),
    do: Energy.record(interval.car_id, field, value, DateTime.add(interval.start_date, offset))

  test "official energy is timestamped, net of recovery and independent of a range coefficient", %{interval: i} do
    sample(i, "EnergyRemaining", 0, 55)
    sample(i, "EnergyRemaining", 600, 52.75)
    result = Energy.drive_energy([i])[i.id]
    assert result.energy_kwh == 2.25
    assert result.coverage == 100
    assert TripEnergy.calculate(i, nil, nil, result).consumption_wh_km == 112.5
    assert DateTime.compare(result.start_sample_at, i.start_date) == :eq
    # Unrelated latest values cannot rewrite the result of this historical trip.
    sample(i, "EnergyRemaining", 3600, 90)
    assert Energy.drive_energy([i])[i.id] == result
  end

  test "net battery gains and measured zero are retained", %{interval: i} do
    sample(i, "EnergyRemaining", 0, 50)
    sample(i, "EnergyRemaining", 600, 51)
    assert Energy.drive_energy([i])[i.id].energy_kwh == -1
    later = %{i | id: i.id + 1, start_date: DateTime.add(i.start_date, 1200), end_date: DateTime.add(i.start_date, 1800)}
    sample(later, "EnergyRemaining", 0, 51)
    sample(later, "EnergyRemaining", 600, 51)
    assert Energy.drive_energy([later])[later.id].energy_kwh == 0
  end

  test "incomplete, invalid and poorly aligned boundaries do not fabricate a complete trip", %{interval: i} do
    sample(i, "EnergyRemaining", -5, 55)
    sample(i, "EnergyRemaining", 31, 54.8)
    sample(i, "EnergyRemaining", 600, 52)
    assert Energy.drive_energy([i]) == %{}
    sample(i, "EnergyRemaining", 0, nil)
    assert Energy.drive_energy([i]) == %{}
    short = %{i | start_date: DateTime.add(i.start_date, 30), end_date: DateTime.add(i.start_date, 60)}
    sample(i, "EnergyRemaining", 50, 54.7)
    assert Energy.drive_energy([short]) == %{}
    assert Energy.drive_energy([%{i | end_date: nil}]) == %{}
  end

  test "duplicates are idempotent and out-of-order history keeps its original timestamp", %{interval: i} do
    sample(i, "EnergyRemaining", 600, 52)
    sample(i, "EnergyRemaining", 0, 55)
    sample(i, "EnergyRemaining", 0, 999)
    assert Energy.drive_energy([i])[i.id].energy_kwh == 3
    assert Repo.query!("SELECT count(*) FROM fleet_energy_samples WHERE car_id=$1", [i.car_id]).rows == [[2]]
  end

  test "vehicle IDs isolate identical time ranges", %{interval: i} do
    sample(i, "EnergyRemaining", 0, 55)
    sample(i, "EnergyRemaining", 600, 52)
    assert Energy.drive_energy([%{i | car_id: i.car_id + 10_000}]) == %{}
  end

  test "AC losses use aligned input and battery counters while keeping user costs separate", %{interval: i} do
    for {field, last} <- [{"ACChargingEnergyIn", 11.0}, {"DCChargingEnergyIn", 10.0}] do
      sample(i, field, 0, 0)
      sample(i, field, 600, last)
    end
    result = Energy.charging_energy([i])[i.id]
    assert result.energy_added == 10
    assert result.energy_used == 11
    assert result.loss_kwh == 1
    assert_in_delta result.loss_percent, 100 / 11, 0.0001
    assert result.battery_source == :fleet_battery
    assert result.input_source == :fleet_ac
  end

  test "DC uses the same battery-side field and never an AC counter for input or losses", %{interval: i} do
    for {field, last} <- [{"ACChargingEnergyIn", 11.0}, {"DCChargingEnergyIn", 10.0}] do
      sample(i, field, 0, 0)
      sample(i, field, 600, last)
    end
    result = Energy.charging_energy([%{i | fast_charger: true}])[i.id]
    assert result.energy_added == 10
    assert result.energy_used == 12
    assert result.input_source == :power_estimate
    assert result.loss_kwh == nil
  end

  test "counter reset, invalid readings and an old session counter force legacy fallback", %{interval: i} do
    sample(i, "DCChargingEnergyIn", 0, 0)
    sample(i, "DCChargingEnergyIn", 200, 5)
    sample(i, "DCChargingEnergyIn", 300, 0)
    sample(i, "DCChargingEnergyIn", 600, 10)
    sample(i, "ACChargingEnergyIn", 0, 7)
    sample(i, "ACChargingEnergyIn", 600, 12)
    result = Energy.charging_energy([i])[i.id]
    assert result.energy_added == 9
    assert result.energy_used == 12
    assert result.loss_kwh == nil
  end

  test "different coverage and negative differences never produce a charging loss", %{interval: i} do
    sample(i, "DCChargingEnergyIn", 0, 0)
    sample(i, "DCChargingEnergyIn", 600, 10)
    sample(i, "ACChargingEnergyIn", 0, 0)
    sample(i, "ACChargingEnergyIn", 590, 9)
    result = Energy.charging_energy([i])[i.id]
    assert result.energy_added == 10
    assert result.energy_used == 9
    assert result.loss_kwh == nil
  end

  test "capacity normalization uses a shared sample and preserves measurement bases", %{interval: i} do
    sample(i, "EnergyRemaining", 0, 48)
    sample(i, "Soc", 0, 80)
    sample(i, "EnergyRemaining", 60, 50)
    sample(i, "Soc", 61, 75)
    sample(i, "EnergyRemaining", 120, 5)
    sample(i, "Soc", 120, 10)
    history = Energy.capacity_history(i.car_id, DateTime.add(i.start_date, -1))
    assert history.source == :fleet_normalized
    assert [%{value: 60.0}] = history.rows
    sample(i, "NominalFullPackEnergyKwh", 180, 61)
    history = Energy.capacity_history(i.car_id, DateTime.add(i.start_date, -1))
    assert history.source == :fleet_capacity
    assert [%{value: 61.0}] = history.rows
  end
end
