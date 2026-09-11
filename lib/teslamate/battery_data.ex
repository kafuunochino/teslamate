defmodule TeslaMate.BatteryData do
  @moduledoc """
  Battery readings from the existing vehicle-data API and recorded samples.
  Each value retains its own source timestamp. Reading a dashboard never wakes
  the vehicle or makes an additional Tesla API request.
  """

  alias TeslaMate.Convert

  @charge_fields ~w(
    battery_level usable_battery_level battery_range ideal_battery_range est_battery_range
    battery_heater_on not_enough_power_to_heat charging_state charge_energy_added
    charge_limit_soc charge_limit_soc_min charge_limit_soc_max charge_limit_soc_std
    charger_power charger_voltage charger_actual_current charger_phases charger_pilot_current
    charge_current_request charge_current_request_max charge_rate time_to_full_charge
    charge_miles_added_rated charge_miles_added_ideal fast_charger_present fast_charger_type
    fast_charger_brand conn_charge_cable charge_port_door_open charge_port_latch
    charge_port_cold_weather_mode scheduled_charging_pending scheduled_charging_start_time
    charge_enable_request user_charge_enable_request charge_to_max_range trip_charging
    max_range_charge_counter managed_charging_active managed_charging_start_time
    managed_charging_user_canceled
  )a
  @climate_fields ~w(battery_heater battery_heater_no_power is_preconditioning smart_preconditioning)a
  @drive_fields ~w(active_route_destination active_route_energy_at_arrival)a
  @stored_fields ~w(
    battery_level usable_battery_level rated_battery_range_km ideal_battery_range_km
    est_battery_range_km battery_heater_on battery_heater battery_heater_no_power
    not_enough_power_to_heat charge_energy_added charger_power charger_voltage
    charger_actual_current charger_phases charger_pilot_current fast_charger_present
    fast_charger_type fast_charger_brand conn_charge_cable
  )a

  def from_vehicle(vehicle) do
    %{
      charge: group(Map.get(vehicle, :charge_state), @charge_fields),
      climate: group(Map.get(vehicle, :climate_state), @climate_fields),
      drive: navigation_group(Map.get(vehicle, :drive_state))
    }
  end

  def readings(live, samples, now \\ DateTime.utc_now()) do
    saved =
      Enum.reduce(samples, %{}, fn
        nil, acc -> acc
        sample, acc -> merge(acc, Map.take(sample, @stored_fields), sample.date, false, :record)
      end)

    data = (live && Map.get(live, :battery_data)) || %{}
    healthy = live && live.healthy == true && live.state in [:online, :driving, :charging]

    Enum.reduce([:charge, :climate, :drive], saved, fn kind, acc ->
      case Map.get(data, kind) do
        %{values: values, measured_at: date} ->
          fresh = healthy == true and recent?(date, now)
          merge(acc, values, date, fresh, :vehicle)

        _ ->
          acc
      end
    end)
    |> derive(:unavailable_level, :battery_level, :usable_battery_level, fn level, usable ->
      if level in 0..100 and usable in 0..100 and level >= usable, do: level - usable
    end)
    |> derive(:full_rated_range_km, :rated_battery_range_km, :battery_level, fn range, level ->
      if range > 0 and level >= 20 and level <= 100, do: range / level * 100
    end)
  end

  def get(data, key), do: Map.get(data || %{}, key)
  def value(data, key), do: case_value(get(data, key))
  defp case_value(%{value: value}), do: value
  defp case_value(_), do: nil

  defp navigation_group(%{active_route_destination: destination} = state)
       when is_binary(destination) and destination != "",
       do: group(state, @drive_fields)

  defp navigation_group(_), do: group(nil, @drive_fields)

  defp group(nil, _fields), do: %{values: %{}, measured_at: nil}

  defp group(state, fields) do
    values = Map.new(fields, fn key -> normalize(key, Map.get(state, key)) end)
    %{values: values, measured_at: timestamp(Map.get(state, :timestamp), :millisecond)}
  end

  defp normalize(:battery_range, value),
    do: {:rated_battery_range_km, distance(value)}

  defp normalize(:ideal_battery_range, value),
    do: {:ideal_battery_range_km, distance(value)}

  defp normalize(:est_battery_range, value),
    do: {:est_battery_range_km, distance(value)}

  defp normalize(:charge_rate, value), do: {:charge_rate_km_h, distance(value)}

  defp normalize(:charge_miles_added_rated, value),
    do: {:charge_range_added_rated_km, distance(value)}

  defp normalize(:charge_miles_added_ideal, value),
    do: {:charge_range_added_ideal_km, distance(value)}

  defp normalize(key, value)
       when key in [:scheduled_charging_start_time, :managed_charging_start_time],
       do: {key, timestamp(value, :second)}

  defp normalize(key, value), do: {key, value}
  defp distance(value) when is_number(value), do: Convert.miles_to_km(value, 2)
  defp distance(_), do: nil

  defp timestamp(value, unit) when is_integer(value) and value > 0 do
    case DateTime.from_unix(value, unit) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp timestamp(_, _), do: nil

  defp recent?(%DateTime{} = date, now), do: DateTime.diff(now, date) in -5..60
  defp recent?(_, _), do: false

  defp merge(acc, values, date, fresh, source) do
    Enum.reduce(values, acc, fn {key, value}, readings ->
      cond do
        value in [
          nil,
          :unknown,
          :invalid,
          "unknown",
          "Unknown",
          "<invalid>",
          "invalid",
          "Invalid",
          ""
        ] ->
          readings

        newer?(date, Map.get(readings, key)) ->
          Map.put(readings, key, %{value: value, measured_at: date, fresh?: fresh, source: source})

        true ->
          readings
      end
    end)
  end

  defp newer?(_date, nil), do: true
  defp newer?(nil, %{measured_at: %DateTime{}}), do: false
  defp newer?(_date, %{measured_at: nil}), do: true
  defp newer?(date, %{measured_at: previous}), do: DateTime.compare(date, previous) != :lt

  # Derived readings must use a single sample; mixing timestamps can manufacture
  # an apparent unavailable SOC or a change in battery capacity.
  defp derive(data, key, left, right, calculate) do
    with %{measured_at: %DateTime{} = date} = a <- get(data, left),
         %{measured_at: ^date} = b <- get(data, right),
         av when is_number(av) <- number(a.value),
         bv when is_number(bv) <- number(b.value),
         result when is_number(result) <- calculate.(av, bv) do
      Map.put(data, key, %{a | value: result, fresh?: a.fresh? and b.fresh?})
    else
      _ -> data
    end
  end

  defp number(%Decimal{} = value), do: Decimal.to_float(value)
  defp number(value), do: value
end
