defmodule TeslaMate.BatteryDataTest do
  use ExUnit.Case, async: true
  alias TeslaMate.BatteryData
  alias TeslaMate.Vehicles.Vehicle.Summary
  alias TeslaApi.Vehicle
  alias TeslaApi.Vehicle.State.{Charge, Climate, Drive}

  @now ~U[2026-09-11 06:00:00Z]

  defp summary(charge, climate \\ nil, drive \\ nil) do
    vehicle = %Vehicle{charge_state: charge, climate_state: climate, drive_state: drive}

    Summary.into(vehicle, %{
      state: {:online, nil},
      since: @now,
      healthy?: true,
      car: nil,
      elevation: nil,
      geofence: nil
    })
  end

  test "decodes battery fields, preserves false and zero, and converts miles once" do
    charge =
      Charge.result(%{
        "timestamp" => DateTime.to_unix(@now, :millisecond),
        "battery_level" => 0,
        "usable_battery_level" => 0,
        "battery_heater_on" => false,
        "charger_voltage" => 0,
        "charge_rate" => 10,
        "charge_miles_added_rated" => 20,
        "charge_limit_soc_min" => 50,
        "charge_limit_soc_max" => 100,
        "fast_charger_present" => false
      })

    data = BatteryData.readings(summary(charge), [], @now)
    assert data.battery_level.value == 0
    assert data.usable_battery_level.value == 0
    assert data.unavailable_level.value == 0
    assert data.battery_heater_on.value == false
    assert data.charger_voltage.value == 0
    assert data.charge_rate_km_h.value == 16.09
    assert data.charge_range_added_rated_km.value == 32.19
    assert data.charge_limit_soc_max.value == 100
    assert data.fast_charger_present.value == false
    refute Map.has_key?(data, :pack_voltage)
    refute Map.has_key?(data, :battery_temperature)
  end

  test "uses charge and climate timestamps independently of fresh streaming data" do
    old = DateTime.add(@now, -300)

    live =
      summary(
        %Charge{timestamp: DateTime.to_unix(old, :millisecond), battery_level: 50},
        %Climate{timestamp: DateTime.to_unix(@now, :millisecond), battery_heater: false},
        %Drive{timestamp: DateTime.to_unix(@now, :millisecond)}
      )

    data = BatteryData.readings(live, [], @now)
    assert DateTime.compare(data.battery_level.measured_at, old) == :eq
    refute data.battery_level.fresh?
    assert data.battery_heater.fresh?
    refute BatteryData.readings(%{live | state: :asleep}, [], @now).battery_heater.fresh?
    refute BatteryData.readings(%{live | healthy: false}, [], @now).battery_heater.fresh?
  end

  test "keeps stored data after restart without presenting it as live" do
    old = DateTime.add(@now, -60)
    stored = %{date: old, battery_level: 55, usable_battery_level: 53, battery_heater_on: false}
    streaming = %{date: @now, battery_level: 54}
    data = BatteryData.readings(nil, [stored, streaming], @now)
    assert data.battery_level.value == 54
    assert data.usable_battery_level.value == 53
    assert data.usable_battery_level.measured_at == old
    refute data.battery_heater_on.fresh?
    refute Map.has_key?(data, :unavailable_level)
  end

  test "newer complete records win over older cached live values including false" do
    old = DateTime.add(@now, -60)

    live =
      summary(%Charge{timestamp: DateTime.to_unix(old, :millisecond), battery_heater_on: true})

    data = BatteryData.readings(live, [%{date: @now, battery_heater_on: false}], @now)
    assert data.battery_heater_on.value == false
    assert data.battery_heater_on.source == :record
    refute data.battery_heater_on.fresh?
  end

  test "derives only from matching samples and rejects invalid SOC combinations" do
    live =
      summary(%Charge{
        timestamp: DateTime.to_unix(@now, :millisecond),
        battery_level: 50,
        usable_battery_level: 48,
        battery_range: 100
      })

    data = BatteryData.readings(live, [], @now)
    assert data.unavailable_level.value == 2
    assert data.full_rated_range_km.value == 321.86

    for {level, usable} <- [{-1, 0}, {101, 100}, {50, 51}] do
      data =
        BatteryData.readings(
          nil,
          [%{date: @now, battery_level: level, usable_battery_level: usable}],
          @now
        )

      refute Map.has_key?(data, :unavailable_level)
    end

    for level <- [0, 19] do
      data =
        BatteryData.readings(
          nil,
          [%{date: @now, battery_level: level, rated_battery_range_km: 100}],
          @now
        )

      refute Map.has_key?(data, :full_rated_range_km)
    end
  end

  test "missing or unknown fields stay absent and missing timestamps never look live" do
    live = summary(%Charge{battery_heater_on: :unknown, battery_level: nil, charger_power: 0})
    data = BatteryData.readings(live, [], @now)
    refute Map.has_key?(data, :battery_heater_on)
    refute Map.has_key?(data, :battery_level)
    refute data.charger_power.fresh?
    assert BatteryData.readings(nil, [], @now) == %{}

    for source <- [:vehicle, :record], value <- ["<invalid>", :invalid, "Invalid"] do
      data =
        if source == :vehicle do
          BatteryData.readings(summary(%Charge{fast_charger_brand: value}), [], @now)
        else
          BatteryData.readings(nil, [%{date: @now, fast_charger_brand: value}], @now)
        end

      refute Map.has_key?(data, :fast_charger_brand)
    end
  end

  test "scheduled times are epoch seconds and disabled or invalid timestamps stay absent" do
    live =
      summary(%Charge{
        scheduled_charging_start_time: DateTime.to_unix(@now),
        managed_charging_start_time: 0
      })

    data = BatteryData.readings(live, [], @now)
    assert data.scheduled_charging_start_time.value == @now
    refute Map.has_key?(data, :managed_charging_start_time)

    data =
      BatteryData.readings(
        summary(%Charge{timestamp: 99_999_999_999_999_999, battery_level: 50}),
        [],
        @now
      )

    refute data.battery_level.fresh?
  end

  test "arrival zero is valid only with active navigation" do
    drive = %Drive{
      timestamp: DateTime.to_unix(@now, :millisecond),
      active_route_energy_at_arrival: 0,
      active_route_destination: "家"
    }

    assert BatteryData.readings(summary(nil, nil, drive), [], @now).active_route_energy_at_arrival.value ==
             0

    data =
      BatteryData.readings(summary(nil, nil, %{drive | active_route_destination: nil}), [], @now)

    refute Map.has_key?(data, :active_route_energy_at_arrival)
  end

  test "temperature values preserve negative and zero readings with their climate timestamp" do
    climate = %Climate{
      timestamp: DateTime.to_unix(@now, :millisecond),
      inside_temp: -5.5,
      outside_temp: 0,
      driver_temp_setting: 21.5,
      passenger_temp_setting: 22,
      is_climate_on: false
    }

    data = BatteryData.readings(summary(nil, climate), [], @now)
    assert data.inside_temp.value == -5.5
    assert data.outside_temp.value == 0
    assert data.driver_temp_setting.value == 21.5
    assert data.passenger_temp_setting.value == 22
    assert data.is_climate_on.value == false
    assert data.cabin_temp_delta.value == -5.5
    assert DateTime.compare(data.inside_temp.measured_at, @now) == :eq
    assert data.inside_temp.fresh?

    refute BatteryData.readings(summary(nil, climate), [], DateTime.add(@now, 120)).inside_temp.fresh?
  end

  test "stored temperature values survive restart without becoming current" do
    stored = %{
      date: @now,
      inside_temp: Decimal.new("-1.5"),
      outside_temp: Decimal.new("0"),
      driver_temp_setting: Decimal.new("21"),
      passenger_temp_setting: Decimal.new("22")
    }

    data = BatteryData.readings(nil, [stored, %{date: DateTime.add(@now, 1)}], @now)
    assert data.inside_temp.value == -1.5
    assert data.outside_temp.value == 0
    assert data.cabin_temp_delta.value == -1.5
    assert data.driver_temp_setting.value == 21
    assert data.inside_temp.source == :record
    refute data.inside_temp.fresh?

    for bad <- [nil, "<invalid>", true, "hot", 999] do
      invalid = %{date: @now, inside_temp: bad}
      refute Map.has_key?(BatteryData.readings(nil, [invalid], @now), :inside_temp)
    end
  end

  test "temperature differences never combine different source times or source types" do
    stored = %{date: @now, inside_temp: 10, outside_temp: 20}
    original = BatteryData.readings(nil, [stored], @now)
    assert original.cabin_temp_delta.value == -10
    changed = put_in(original, [:outside_temp, :measured_at], DateTime.add(@now, 1))
    refute Map.has_key?(BatteryData.derive_temperature_delta(changed), :cabin_temp_delta)
    changed = put_in(original, [:outside_temp, :source], :telemetry)
    refute Map.has_key?(BatteryData.derive_temperature_delta(changed), :cabin_temp_delta)
  end

  test "state-test deduplication ignores only timestamps and retains changed battery values" do
    pid = start_supervised!({PubSubMock, name: __MODULE__, pid: self()})

    live =
      summary(%Charge{timestamp: DateTime.to_unix(@now, :millisecond), battery_heater_on: false})

    :ok = PubSubMock.broadcast(pid, :test, "battery", live)
    assert_receive {:pubsub, {:broadcast, :test, "battery", ^live}}

    newer =
      summary(%Charge{
        timestamp: DateTime.to_unix(DateTime.add(@now, 1), :millisecond),
        battery_heater_on: false
      })

    :ok = PubSubMock.broadcast(pid, :test, "battery", newer)
    refute_receive {:pubsub, _}

    changed =
      summary(%Charge{timestamp: DateTime.to_unix(@now, :millisecond), battery_heater_on: true})

    :ok = PubSubMock.broadcast(pid, :test, "battery", changed)
    assert_receive {:pubsub, {:broadcast, :test, "battery", ^changed}}
  end
end
