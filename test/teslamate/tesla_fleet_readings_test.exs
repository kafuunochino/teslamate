defmodule TeslaMate.TeslaFleet.ReadingsTest do
  use TeslaMate.DataCase, async: false
  alias TeslaMate.{Log, TeslaFleet}
  alias TeslaMate.TeslaFleet.{Connection, Readings}
  @vin "LRW3E7EK9MC123456"

  setup do
    start_supervised!(TeslaMate.Vault)
    id = System.unique_integer([:positive])
    {:ok, car} = Log.create_car(%{eid: id, vid: id, vin: @vin, model: "3"})

    Repo.insert!(%Connection{
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

  test "known vehicle access is removed when the OAuth connection is removed", %{now: now} do
    assert :ok = TeslaFleet.known_vehicle(@vin)
    Repo.delete_all(Connection)
    assert :ignored = Readings.ingest(@vin, "PackVoltage", payload(350, now))
  end

  test "base config omits firmware-gated fields and uses bounded intervals" do
    fields = Readings.field_config(5)
    refute Map.has_key?(fields, "NominalFullPackEnergyKwh")
    assert fields["PackCurrent"]["interval_seconds"] == 5
    assert fields["ModuleTempMax"]["interval_seconds"] == 10
  end
end
