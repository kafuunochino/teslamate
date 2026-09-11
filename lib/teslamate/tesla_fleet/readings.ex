defmodule TeslaMate.TeslaFleet.Readings do
  @moduledoc "Timestamped Fleet Telemetry readings. Unknown VINs and fields are never imported."
  import Ecto.Query
  alias TeslaMate.{Repo, TeslaFleet}

  @fields %{
    "PackVoltage" => {:pack_voltage, :number, 0, 1500},
    "PackCurrent" => {:pack_current, :number, -3000, 3000},
    "ModuleTempMax" => {:module_temp_max, :number, -100, 250},
    "ModuleTempMin" => {:module_temp_min, :number, -100, 250},
    "InsideTemp" => {:inside_temp, :number, -100, 250},
    "OutsideTemp" => {:outside_temp, :number, -100, 250},
    "HvacLeftTemperatureRequest" => {:hvac_left_temp_setting, :number, -100, 250},
    "HvacRightTemperatureRequest" => {:hvac_right_temp_setting, :number, -100, 250},
    "DiStatorTempF" => {:front_motor_temp, :number, -100, 500},
    "DiStatorTempR" => {:rear_motor_temp, :number, -100, 500},
    "DiStatorTempREL" => {:rear_left_motor_temp, :number, -100, 500},
    "DiStatorTempRER" => {:rear_right_motor_temp, :number, -100, 500},
    "DiInverterTF" => {:front_inverter_temp, :number, -100, 250},
    "DiInverterTR" => {:rear_inverter_temp, :number, -100, 250},
    "DiInverterTREL" => {:rear_left_inverter_temp, :number, -100, 250},
    "DiInverterTRER" => {:rear_right_inverter_temp, :number, -100, 250},
    "DiHeatsinkTF" => {:front_heatsink_temp, :number, -100, 300},
    "DiHeatsinkTR" => {:rear_heatsink_temp, :number, -100, 300},
    "DiHeatsinkTREL" => {:rear_left_heatsink_temp, :number, -100, 300},
    "DiHeatsinkTRER" => {:rear_right_heatsink_temp, :number, -100, 300},
    "BrickVoltageMax" => {:brick_voltage_max, :number, 0, 10},
    "BrickVoltageMin" => {:brick_voltage_min, :number, 0, 10},
    "NumBrickVoltageMax" => {:num_brick_voltage_max, :integer, 1, 2000},
    "NumBrickVoltageMin" => {:num_brick_voltage_min, :integer, 1, 2000},
    "NumModuleTempMax" => {:num_module_temp_max, :integer, 0, 2000},
    "NumModuleTempMin" => {:num_module_temp_min, :integer, 0, 2000},
    "EnergyRemaining" => {:energy_remaining, :number, 0, 2000},
    "LifetimeEnergyUsed" => {:lifetime_energy_used, :number, 0, 10_000_000},
    "BMSState" => {:bms_state, :enum, nil, nil},
    "Hvil" => {:hvil, :enum, nil, nil},
    "BatteryLevel" => {:battery_level, :number, 0, 100},
    "Soc" => {:usable_battery_level, :number, 0, 100},
    "BatteryHeaterOn" => {:battery_heater_on, :boolean, nil, nil},
    "NotEnoughPowerToHeat" => {:not_enough_power_to_heat, :boolean, nil, nil},
    "PreconditioningEnabled" => {:is_preconditioning, :boolean, nil, nil},
    "ChargeLimitSoc" => {:charge_limit_soc, :number, 0, 100},
    "ChargerVoltage" => {:charger_voltage, :number, 0, 1500},
    "ACChargingPower" => {:ac_charging_power, :number, 0, 1000},
    "DCChargingPower" => {:dc_charging_power, :number, 0, 2000},
    "ACChargingEnergyIn" => {:ac_charging_energy_in, :number, 0, 2000},
    "DCChargingEnergyIn" => {:dc_charging_energy_in, :number, 0, 2000},
    "NominalFullPackEnergyKwh" => {:nominal_full_pack_energy, :number, 0, 2000},
    "BrickSocMinPercent" => {:brick_soc_min, :number, 0, 100},
    "LifetimeEnergyChargedKwh" => {:lifetime_charged_energy, :number, 0, 10_000_000}
  }
  @new_fields ~w(NominalFullPackEnergyKwh BrickSocMinPercent LifetimeEnergyChargedKwh)
  @enums %{
    "BMSState" =>
      ~w(BMSStateStandby BMSStateDrive BMSStateSupport BMSStateCharge BMSStateFEIM BMSStateClearFault BMSStateFault BMSStateWeld BMSStateTest),
    "Hvil" => ~w(HvilStatusFault HvilStatusOK)
  }

  def field_config(interval, include_new \\ false) do
    @fields
    |> Map.keys()
    |> Enum.reject(&(!include_new and &1 in @new_fields))
    |> Map.new(
      &{&1,
       %{
         "interval_seconds" =>
           if(&1 in ~w(PackVoltage PackCurrent), do: interval, else: max(interval, 10))
       }}
    )
  end

  def decode(field, %{"value" => raw, "created_at" => time}, now \\ DateTime.utc_now()) do
    with {key, type, min, max} <- @fields[field],
         {:ok, date, _} <- DateTime.from_iso8601(time),
         true <- DateTime.diff(date, now) <= 60 and date.year >= 2020 do
      value = normalize(raw, type, min, max, field)
      {:ok, key, value, date}
    else
      _ -> {:error, :invalid_reading}
    end
  rescue
    _ -> {:error, :invalid_reading}
  end

  def ingest(vin, field, payload) when is_binary(payload) and byte_size(payload) <= 4096 do
    with {:ok, %{"value" => _, "created_at" => _} = data} <- Jason.decode(payload),
         {:ok, _key, value, date} <- decode(field, data),
         :ok <- TeslaFleet.known_vehicle(vin),
         car_id when is_integer(car_id) <-
           Repo.one(from c in TeslaMate.Log.Car, where: c.vin == ^vin, select: c.id) do
      data = %{"value" => value, "invalid" => is_nil(value)}

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO public.fleet_readings (car_id, field, data, measured_at, received_at)
        VALUES ($1, $2, $3::jsonb, $4, $5)
        ON CONFLICT (car_id, field) DO UPDATE
        SET data = EXCLUDED.data, measured_at = EXCLUDED.measured_at, received_at = EXCLUDED.received_at
        WHERE fleet_readings.measured_at < EXCLUDED.measured_at
        """,
        [car_id, field, data, date, DateTime.utc_now()]
      )

      :ok
    else
      _ -> :ignored
    end
  end

  def ingest(_, _, _), do: :ignored

  def merge_readings(existing, car_id, now \\ DateTime.utc_now()) do
    rows =
      Repo.all(
        from r in "fleet_readings",
          where: r.car_id == ^car_id,
          select: %{
            field: r.field,
            data: r.data,
            measured_at: type(r.measured_at, :utc_datetime_usec)
          }
      )

    Enum.reduce(rows, existing, fn row, acc ->
      case @fields[row.field] do
        {key, _, _, _} ->
          previous = acc[key]

          if is_nil(previous) or is_nil(previous.measured_at) or
               DateTime.compare(row.measured_at, previous.measured_at) != :lt do
            reading = %{
              value: row.data["value"],
              measured_at: row.measured_at,
              fresh?: not row.data["invalid"] and DateTime.diff(now, row.measured_at) in -5..60,
              source: :telemetry
            }

            Map.put(acc, key, reading)
          else
            acc
          end

        _ ->
          acc
      end
    end)
    |> difference(:unavailable_level, :battery_level, :usable_battery_level, 1)
    |> difference(:brick_voltage_delta_mv, :brick_voltage_max, :brick_voltage_min, 1000)
    |> difference(:module_temp_delta, :module_temp_max, :module_temp_min, 1)
    |> TeslaMate.BatteryData.derive_temperature_delta()
  end

  def last_received(car_id) do
    Repo.one(
      from r in "fleet_readings",
        where: r.car_id == ^car_id,
        select: type(max(r.received_at), :utc_datetime_usec)
    )
  end

  defp difference(data, key, a, b, factor) do
    with %{value: av, measured_at: time} = left when is_number(av) <- data[a],
         %{value: bv, measured_at: ^time} = right when is_number(bv) <- data[b],
         true <- av >= bv do
      Map.put(data, key, %{left | value: (av - bv) * factor, fresh?: left.fresh? and right.fresh?})
    else
      _ -> Map.delete(data, key)
    end
  end

  defp normalize(value, :boolean, _, _, _) when is_boolean(value), do: value
  defp normalize("true", :boolean, _, _, _), do: true
  defp normalize("false", :boolean, _, _, _), do: false
  defp normalize(value, :enum, _, _, field), do: if(value in @enums[field], do: value)

  defp normalize(value, type, min, max, field)
       when is_binary(value) and type in [:number, :integer] do
    case Float.parse(value) do
      {number, ""} -> normalize(number, type, min, max, field)
      _ -> nil
    end
  end

  defp normalize(value, type, min, max, _)
       when is_number(value) and type in [:number, :integer] do
    if value >= min and value <= max and (type != :integer or trunc(value) == value), do: value
  end

  defp normalize(_, _, _, _, _), do: nil
end
