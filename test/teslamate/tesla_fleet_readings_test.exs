defmodule TeslaMate.TeslaFleet.ReadingsTest do
  use TeslaMate.DataCase, async: false
  alias TeslaMate.{Log, TeslaFleet}
  alias TeslaMate.TeslaFleet.{Connection, Readings}
  @vin "LRW3E7EK9MC123456"

  setup do
    start_supervised!(TeslaMate.Vault)
    id = System.unique_integer([:positive])
    {:ok, car} = Log.create_car(%{eid: id, vid: id, vin: @vin, model: "3"})

    user =
      Repo.insert!(%TeslaMate.Accounts.User{
        email: "fleet-owner-#{id}@example.com",
        name: "Fleet Owner",
        role: :admin,
        password_hash: "test-only",
        password_changed_at: DateTime.utc_now()
      })

    {:ok, _} = TeslaMate.Accounts.grant_car(user, user, car.id)

    Repo.insert!(%Connection{
      authorized_by_id: user.id,
      id: 1,
      access: "test-access",
      refresh: "test-refresh",
      expires_at: DateTime.add(DateTime.utc_now(), 3600),
      vehicles: %{@vin => %{}}
    })

    %{car: car, now: DateTime.utc_now()}
  end

  defp payload(value, time),
    do: Jason.encode!(%{"value" => value, "created_at" => DateTime.to_iso8601(time)})

  test "zero, negative currents and false survive decoding", %{car: car, now: now} do
    assert :ok = Readings.ingest(@vin, "PackCurrent", payload(0, now))
    assert :ok = Readings.ingest(@vin, "BatteryHeaterOn", payload(false, now))
    data = Readings.merge_readings(%{}, car.id, now)
    assert data.pack_current.value == 0
    assert data.battery_heater_on.value == false
    assert data.pack_current.fresh?
    assert :ok = Readings.ingest(@vin, "PackCurrent", payload("-25.5", DateTime.add(now, 1)))
    assert Readings.merge_readings(%{}, car.id).pack_current.value == -25.5
  end

  test "stored samples survive process-free reads and delayed MQTT replay cannot replace them", %{
    car: car,
    now: now
  } do
    old = DateTime.add(now, -3600)
    assert :ok = Readings.ingest(@vin, "PackVoltage", payload(350, old))
    assert :ok = Readings.ingest(@vin, "PackVoltage", payload(360, now))
    assert :ok = Readings.ingest(@vin, "PackVoltage", payload(340, old))
    data = Readings.merge_readings(%{}, car.id, DateTime.add(now, 120))
    assert data.pack_voltage.value == 360
    assert data.pack_voltage.measured_at == now
    refute data.pack_voltage.fresh?
  end

  test "invalid new samples clear a previous value and are not zero", %{car: car, now: now} do
    Readings.ingest(@vin, "ModuleTempMax", payload(32, now))
    Readings.ingest(@vin, "ModuleTempMax", payload("<invalid>", DateTime.add(now, 1)))
    reading = Readings.merge_readings(%{}, car.id).module_temp_max
    assert reading.value == nil
    refute reading.fresh?
  end

  test "unknown VIN, unknown field, missing timestamp and future values are rejected", %{
    car: car,
    now: now
  } do
    assert :ignored = Readings.ingest("LRW3E7EK9MC999999", "PackVoltage", payload(350, now))
    assert :ignored = Readings.ingest(@vin, "ArbitraryAtom", payload(350, now))
    assert :ignored = Readings.ingest(@vin, "PackVoltage", "350")
    assert :ignored = Readings.ingest(@vin, "PackVoltage", payload(350, DateTime.add(now, 600)))
    assert :ignored = Readings.ingest(@vin, "PackVoltage", String.duplicate("x", 5000))
    assert Readings.merge_readings(%{}, car.id) == %{}
  end

  test "voltage spread only uses a shared vehicle timestamp", %{car: car, now: now} do
    Readings.ingest(@vin, "BrickVoltageMax", payload(3.501, now))
    Readings.ingest(@vin, "BrickVoltageMin", payload(3.49, now))
    assert_in_delta Readings.merge_readings(%{}, car.id).brick_voltage_delta_mv.value, 11, 0.00001
    Readings.ingest(@vin, "BrickVoltageMax", payload(3.502, DateTime.add(now, 1)))
    refute Map.has_key?(Readings.merge_readings(%{}, car.id), :brick_voltage_delta_mv)
  end

  test "temperature config requests motor, inverter, ambient and setpoint signals", %{now: now} do
    fields = Readings.field_config(5)

    for {field, key} <- [
          {"DiStatorTempF", :front_motor_temp},
          {"DiStatorTempR", :rear_motor_temp},
          {"DiStatorTempREL", :rear_left_motor_temp},
          {"DiStatorTempRER", :rear_right_motor_temp},
          {"DiInverterTF", :front_inverter_temp},
          {"DiInverterTR", :rear_inverter_temp},
          {"DiInverterTREL", :rear_left_inverter_temp},
          {"DiInverterTRER", :rear_right_inverter_temp},
          {"DiHeatsinkTF", :front_heatsink_temp},
          {"DiHeatsinkTR", :rear_heatsink_temp},
          {"DiHeatsinkTREL", :rear_left_heatsink_temp},
          {"DiHeatsinkTRER", :rear_right_heatsink_temp},
          {"InsideTemp", :inside_temp},
          {"OutsideTemp", :outside_temp},
          {"HvacLeftTemperatureRequest", :hvac_left_temp_setting},
          {"HvacRightTemperatureRequest", :hvac_right_temp_setting}
        ] do
      assert fields[field]["interval_seconds"] == 10

      assert {:ok, ^key, 0, ^now} =
               Readings.decode(field, %{"value" => 0, "created_at" => DateTime.to_iso8601(now)})
    end
  end

  test "new telemetry temperatures persist and obsolete cabin differences are discarded", %{
    car: car,
    now: now
  } do
    for {field, value} <- [
          {"InsideTemp", -5},
          {"OutsideTemp", 0},
          {"ModuleTempMax", 35},
          {"ModuleTempMin", 30},
          {"DiStatorTempR", 62},
          {"DiInverterTR", 31.5}
        ] do
      assert :ok = Readings.ingest(@vin, field, payload(value, now))
    end

    data = Readings.merge_readings(%{}, car.id, now)
    assert data.cabin_temp_delta.value == -5
    assert data.module_temp_delta.value == 5
    assert data.rear_motor_temp.value == 62
    assert data.rear_inverter_temp.value == 31.5
    assert data.rear_motor_temp.source == :telemetry

    Readings.ingest(@vin, "OutsideTemp", payload(1, DateTime.add(now, 1)))
    Readings.ingest(@vin, "ModuleTempMax", payload(36, DateTime.add(now, 1)))
    data = Readings.merge_readings(data, car.id, DateTime.add(now, 120))
    refute Map.has_key?(data, :cabin_temp_delta)
    refute Map.has_key?(data, :module_temp_delta)
    refute data.rear_motor_temp.fresh?

    Readings.ingest(@vin, "DiStatorTempR", payload("<invalid>", DateTime.add(now, 2)))
    assert Readings.merge_readings(%{}, car.id).rear_motor_temp.value == nil
  end

  test "known vehicle access is removed when the OAuth connection is removed", %{now: now} do
    assert :ok = TeslaFleet.known_vehicle(@vin)
    Repo.delete_all(Connection)
    assert :ignored = Readings.ingest(@vin, "PackVoltage", payload(350, now))
  end

  test "ingestion writes durable energy history atomically without storing unknown vehicles", %{
    car: car,
    now: now
  } do
    assert :ignored = Readings.ingest("UNKNOWN", "EnergyRemaining", payload(50, now))
    assert :ok = Readings.ingest(@vin, "EnergyRemaining", payload(50, now))
    assert :ok = Readings.ingest(@vin, "EnergyRemaining", payload(50, now))

    assert :ok =
             Readings.ingest(@vin, "EnergyRemaining", payload("<invalid>", DateTime.add(now, 1)))

    assert Repo.query!(
             "SELECT value FROM fleet_energy_samples WHERE car_id=$1 ORDER BY measured_at",
             [car.id]
           ).rows == [[50.0], [nil]]

    assert Readings.merge_readings(%{}, car.id).energy_remaining.value == nil
  end

  test "base config omits firmware-gated fields and uses bounded intervals" do
    fields = Readings.field_config(5)
    refute Map.has_key?(fields, "NominalFullPackEnergyKwh")
    assert fields["PackCurrent"]["interval_seconds"] == 5
    assert fields["ModuleTempMax"]["interval_seconds"] == 10
  end
  test "vehicle firmware enables only supported capacity and paired energy fields" do
    for info <- [%{}, %{"firmware_version" => "unknown"}, %{"firmware_version" => "2026.8.300", "fleet_telemetry_version" => "1.2.0"}] do
      fields = Readings.field_config_for_vehicle(5, info)
      refute Map.has_key?(fields, "NominalFullPackEnergyKwh")
      refute Map.has_key?(fields["EnergyRemaining"], "include_fields")
    end

    paired = Readings.field_config_for_vehicle(10, %{"firmware_version" => "2026.26.6", "fleet_telemetry_version" => "1.3.0"})
    assert paired["EnergyRemaining"]["include_fields"] == ["Soc"]
    refute Map.has_key?(paired, "NominalFullPackEnergyKwh")

    fields = Readings.field_config_for_vehicle(30, %{"firmware_version" => "2026.32.1 abc123", "fleet_telemetry_version" => "1.3.0"})
    assert fields["NominalFullPackEnergyKwh"]["interval_seconds"] == 30
    assert fields["BMSState"]["include_fields"] == ["EnergyRemaining", "Soc"]
    assert fields["ACChargingEnergyIn"]["include_fields"] == ["DCChargingEnergyIn"]
    assert Readings.field_config_for_vehicle(30, %{"firmware_version" => "2026.32"})["NominalFullPackEnergyKwh"]
  end
end
