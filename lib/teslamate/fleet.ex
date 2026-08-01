defmodule TeslaMate.Fleet do
  @moduledoc """
  Read-only, authorization-aware queries for the unified web platform.

  Every public function accepts the current platform user and resolves a car
  through `TeslaMate.Accounts` before querying telemetry. This is the primary
  defence against cross-tenant IDOR vulnerabilities.
  """

  import Ecto.Query, warn: false

  alias TeslaMate.Accounts
  alias TeslaMate.Accounts.User
  alias TeslaMate.Locations.{Address, GeoFence}
  alias TeslaMate.Log.{Car, ChargingProcess, Drive, Position, State, Update}
  alias TeslaMate.Repo
  alias TeslaMate.Vehicles

  @allowed_ranges [7, 30, 90, 365]

  def home(%User{} = user, requested_car_id \\ nil) do
    {cars, car} = resolve_vehicle(user, requested_car_id)

    if car do
      position = latest_position(car.id)
      live = live_summary(car.id)

      %{
        cars: cars,
        car: car,
        live: live,
        position: position,
        state: current_state(car.id),
        update: latest_update(car.id),
        location: latest_location(car.id),
        drive_stats: drive_stats(car.id, 30),
        charge_stats: charge_stats(car.id, 30),
        recent_drives: recent_drives(car.id, 5),
        recent_charges: recent_charges(car.id, 5),
        daily_distance: daily_distance(car.id, 14)
      }
    else
      empty_report(cars)
    end
  end

  def trips(%User{} = user, requested_car_id, requested_days \\ 30) do
    days = normalize_days(requested_days)
    {cars, car} = resolve_vehicle(user, requested_car_id)

    if car do
      since = since(days)

      drives =
        Drive
        |> where([d], d.car_id == ^car.id and d.start_date >= ^since)
        |> order_by([d], desc: d.start_date, desc: d.id)
        |> limit(150)
        |> preload([:start_address, :end_address, :start_geofence, :end_geofence])
        |> Repo.all()

      %{
        cars: cars,
        car: car,
        days: days,
        drives: drives,
        stats: drive_stats(car.id, days),
        daily_distance: daily_distance(car.id, days),
        destinations: top_destinations(car.id, days, 8)
      }
    else
      empty_report(cars) |> Map.merge(%{days: days, drives: [], destinations: []})
    end
  end

  def trip(%User{} = user, drive_id) do
    accessible_ids = accessible_car_ids(user)

    drive =
      Drive
      |> where([d], d.id == ^parse_id(drive_id) and d.car_id in ^accessible_ids)
      |> preload([:car, :start_address, :end_address, :start_geofence, :end_geofence])
      |> Repo.one()

    case drive do
      nil ->
        nil

      drive ->
        positions =
          Position
          |> where([p], p.drive_id == ^drive.id)
          |> order_by([p], asc: p.date, asc: p.id)
          |> select([p], %{
            latitude: p.latitude,
            longitude: p.longitude,
            elevation: p.elevation,
            speed: p.speed,
            power: p.power,
            battery_level: p.battery_level,
            date: p.date
          })
          |> Repo.all()

        %{drive: drive, positions: positions}
    end
  end

  def battery(%User{} = user, requested_car_id, requested_days \\ 90) do
    days = normalize_days(requested_days)
    {cars, car} = resolve_vehicle(user, requested_car_id)

    if car do
      history = battery_history(car.id, days)

      %{
        cars: cars,
        car: Repo.preload(car, :settings),
        days: days,
        position: latest_position(car.id),
        live: live_summary(car.id),
        history: history,
        degradation: degradation(history),
        charge_stats: charge_stats(car.id, days),
        daily_energy: daily_charge_energy(car.id, days),
        pressures: latest_pressures(car.id)
      }
    else
      empty_report(cars)
      |> Map.merge(%{days: days, history: [], degradation: nil, daily_energy: [], pressures: %{}})
    end
  end

  def charging(%User{} = user, requested_car_id, requested_days \\ 90) do
    days = normalize_days(requested_days)
    {cars, car} = resolve_vehicle(user, requested_car_id)

    if car do
      %{
        cars: cars,
        car: car,
        days: days,
        stats: charge_stats(car.id, days),
        sessions: recent_charges(car.id, 100, days),
        daily_energy: daily_charge_energy(car.id, days),
        stations: top_charging_stations(car.id, days, 10)
      }
    else
      empty_report(cars)
      |> Map.merge(%{days: days, sessions: [], daily_energy: [], stations: []})
    end
  end

  def analysis(%User{} = user, requested_car_id, requested_days \\ 90) do
    days = normalize_days(requested_days)
    {cars, car} = resolve_vehicle(user, requested_car_id)

    if car do
      drive = analysis_drive_metrics(car, days)
      charging = analysis_charge_metrics(car.id, days)
      scores = scores(drive, charging)

      %{
        cars: cars,
        car: car,
        days: days,
        drive: drive,
        charging: charging,
        scores: scores,
        recommendations: recommendations(drive, charging, scores),
        destinations: top_destinations(car.id, days, 10),
        stations: top_charging_stations(car.id, days, 10),
        monthly_distance: monthly_distance(car.id, min(days, 365))
      }
    else
      empty_report(cars)
      |> Map.merge(%{
        days: days,
        drive: %{},
        charging: %{},
        scores: %{overall: nil, efficiency: nil, charging: nil, usage: nil},
        recommendations: [],
        destinations: [],
        stations: [],
        monthly_distance: []
      })
    end
  end

  def vehicle_label(%Car{name: name}) when is_binary(name) and name != "", do: name

  def vehicle_label(%Car{marketing_name: marketing_name})
      when is_binary(marketing_name) and marketing_name != "",
      do: marketing_name

  def vehicle_label(%Car{id: id}), do: "车辆 ##{id}"

  def vin_suffix(%Car{vin: vin}) when is_binary(vin) and byte_size(vin) >= 6,
    do: String.slice(vin, -6, 6)

  def vin_suffix(_), do: "未知"

  def address_label(nil), do: "未知位置"

  def address_label(%Address{} = address) do
    address.name || address.road || address.city || address.display_name || "未知位置"
  end

  def address_label(%GeoFence{name: name}), do: name

  ## Query helpers

  defp resolve_vehicle(user, requested_car_id) do
    cars = Accounts.list_accessible_cars(user)

    requested =
      if requested_car_id in [nil, ""] do
        nil
      else
        Accounts.get_accessible_car(user, requested_car_id)
      end

    {cars, requested || List.first(cars)}
  end

  defp accessible_car_ids(user), do: user |> Accounts.list_accessible_cars() |> Enum.map(& &1.id)

  defp latest_position(car_id) do
    Position
    |> where([p], p.car_id == ^car_id)
    |> order_by([p], desc: p.date, desc: p.id)
    |> limit(1)
    |> Repo.one()
  end

  defp latest_pressures(car_id) do
    Position
    |> where(
      [p],
      p.car_id == ^car_id and
        (not is_nil(p.tpms_pressure_fl) or not is_nil(p.tpms_pressure_fr) or
           not is_nil(p.tpms_pressure_rl) or not is_nil(p.tpms_pressure_rr))
    )
    |> order_by([p], desc: p.date, desc: p.id)
    |> select([p], %{
      fl: p.tpms_pressure_fl,
      fr: p.tpms_pressure_fr,
      rl: p.tpms_pressure_rl,
      rr: p.tpms_pressure_rr,
      measured_at: p.date
    })
    |> limit(1)
    |> Repo.one()
    |> Kernel.||(%{})
  end

  defp current_state(car_id) do
    State
    |> where([s], s.car_id == ^car_id)
    |> order_by([s], desc: s.start_date, desc: s.id)
    |> limit(1)
    |> Repo.one()
  end

  defp latest_update(car_id) do
    Update
    |> where([u], u.car_id == ^car_id)
    |> order_by([u], desc: u.start_date, desc: u.id)
    |> limit(1)
    |> Repo.one()
  end

  defp latest_location(car_id) do
    Drive
    |> where([d], d.car_id == ^car_id)
    |> order_by([d], desc: d.start_date, desc: d.id)
    |> preload([:end_address, :end_geofence, :start_address, :start_geofence])
    |> limit(1)
    |> Repo.one()
    |> case do
      nil ->
        nil

      drive ->
        drive.end_geofence || drive.end_address || drive.start_geofence || drive.start_address
    end
  end

  defp drive_stats(car_id, days) do
    Drive
    |> where([d], d.car_id == ^car_id and d.start_date >= ^since(days))
    |> select([d], %{
      count: count(d.id),
      distance: fragment("COALESCE(SUM(?), 0)", d.distance),
      duration_min: fragment("COALESCE(SUM(?), 0)", d.duration_min),
      average_distance: fragment("COALESCE(AVG(?), 0)", d.distance),
      max_speed: fragment("COALESCE(MAX(?), 0)", d.speed_max)
    })
    |> Repo.one()
  end

  defp charge_stats(car_id, days) do
    ChargingProcess
    |> where([c], c.car_id == ^car_id and c.start_date >= ^since(days))
    |> select([c], %{
      count: count(c.id),
      energy_added: fragment("COALESCE(SUM(?), 0)", c.charge_energy_added),
      energy_used: fragment("COALESCE(SUM(?), 0)", c.charge_energy_used),
      cost: fragment("COALESCE(SUM(?), 0)", c.cost),
      duration_min: fragment("COALESCE(SUM(?), 0)", c.duration_min),
      average_end_level: avg(c.end_battery_level)
    })
    |> Repo.one()
  end

  defp recent_drives(car_id, limit) do
    Drive
    |> where([d], d.car_id == ^car_id)
    |> order_by([d], desc: d.start_date, desc: d.id)
    |> limit(^limit)
    |> preload([:start_address, :end_address, :start_geofence, :end_geofence])
    |> Repo.all()
  end

  defp recent_charges(car_id, limit, days \\ nil) do
    ChargingProcess
    |> where([c], c.car_id == ^car_id)
    |> maybe_since(days)
    |> order_by([c], desc: c.start_date, desc: c.id)
    |> limit(^limit)
    |> preload([:address, :geofence])
    |> Repo.all()
  end

  defp maybe_since(query, nil), do: query
  defp maybe_since(query, days), do: where(query, [c], c.start_date >= ^since(days))

  defp daily_distance(car_id, days) do
    Drive
    |> where([d], d.car_id == ^car_id and d.start_date >= ^since(days))
    |> group_by([d], fragment("date_trunc('day', ?)", d.start_date))
    |> order_by([d], fragment("date_trunc('day', ?)", d.start_date))
    |> select([d], %{
      period: fragment("date_trunc('day', ?)", d.start_date),
      value: fragment("COALESCE(SUM(?), 0)", d.distance)
    })
    |> Repo.all()
  end

  defp monthly_distance(car_id, days) do
    Drive
    |> where([d], d.car_id == ^car_id and d.start_date >= ^since(days))
    |> group_by([d], fragment("date_trunc('month', ?)", d.start_date))
    |> order_by([d], fragment("date_trunc('month', ?)", d.start_date))
    |> select([d], %{
      period: fragment("date_trunc('month', ?)", d.start_date),
      value: fragment("COALESCE(SUM(?), 0)", d.distance)
    })
    |> Repo.all()
  end

  defp daily_charge_energy(car_id, days) do
    ChargingProcess
    |> where([c], c.car_id == ^car_id and c.start_date >= ^since(days))
    |> group_by([c], fragment("date_trunc('day', ?)", c.start_date))
    |> order_by([c], fragment("date_trunc('day', ?)", c.start_date))
    |> select([c], %{
      period: fragment("date_trunc('day', ?)", c.start_date),
      value: fragment("COALESCE(SUM(?), 0)", c.charge_energy_added),
      cost: fragment("COALESCE(SUM(?), 0)", c.cost)
    })
    |> Repo.all()
  end

  defp battery_history(car_id, days) do
    Position
    |> where(
      [p],
      p.car_id == ^car_id and p.date >= ^since(days) and p.battery_level >= 20 and
        not is_nil(p.rated_battery_range_km) and p.rated_battery_range_km > 0
    )
    |> group_by([p], fragment("date_trunc('day', ?)", p.date))
    |> order_by([p], fragment("date_trunc('day', ?)", p.date))
    |> select([p], %{
      period: fragment("date_trunc('day', ?)", p.date),
      full_range:
        fragment("AVG((? / NULLIF(?, 0)) * 100.0)", p.rated_battery_range_km, p.battery_level),
      average_level: avg(p.battery_level)
    })
    |> Repo.all()
  end

  defp degradation(history) when length(history) >= 7 do
    sample_size = min(14, max(div(length(history), 3), 3))
    baseline = history |> Enum.take(sample_size) |> average_field(:full_range)
    current = history |> Enum.take(-sample_size) |> average_field(:full_range)

    if baseline && current && baseline > 0 do
      %{
        baseline_range: baseline,
        current_range: current,
        loss_percent: max(0.0, (baseline - current) / baseline * 100)
      }
    end
  end

  defp degradation(_), do: nil

  defp top_destinations(car_id, days, limit) do
    Drive
    |> join(:left, [d], a in Address, on: a.id == d.end_address_id)
    |> join(:left, [d, a], g in GeoFence, on: g.id == d.end_geofence_id)
    |> where([d], d.car_id == ^car_id and d.start_date >= ^since(days))
    |> where([d, a, g], not is_nil(a.id) or not is_nil(g.id))
    |> group_by([d, a, g], [g.id, g.name, a.id, a.name, a.road, a.city, a.display_name])
    |> order_by([d], desc: count(d.id))
    |> limit(^limit)
    |> select([d, a, g], %{
      label: fragment("COALESCE(?, ?, ?, ?, ?)", g.name, a.name, a.road, a.city, a.display_name),
      count: count(d.id),
      distance: fragment("COALESCE(SUM(?), 0)", d.distance)
    })
    |> Repo.all()
  end

  defp top_charging_stations(car_id, days, limit) do
    ChargingProcess
    |> join(:left, [c], a in Address, on: a.id == c.address_id)
    |> join(:left, [c, a], g in GeoFence, on: g.id == c.geofence_id)
    |> where([c], c.car_id == ^car_id and c.start_date >= ^since(days))
    |> group_by([c, a, g], [g.id, g.name, a.id, a.name, a.road, a.city, a.display_name])
    |> order_by([c], desc: count(c.id))
    |> limit(^limit)
    |> select([c, a, g], %{
      label:
        fragment(
          "COALESCE(?, ?, ?, ?, ?, '未知充电地点')",
          g.name,
          a.name,
          a.road,
          a.city,
          a.display_name
        ),
      count: count(c.id),
      energy: fragment("COALESCE(SUM(?), 0)", c.charge_energy_added),
      cost: fragment("COALESCE(SUM(?), 0)", c.cost)
    })
    |> Repo.all()
  end

  defp analysis_drive_metrics(%Car{} = car, days) do
    Drive
    |> where([d], d.car_id == ^car.id and d.start_date >= ^since(days))
    |> select([d], %{
      count: count(d.id),
      distance: fragment("COALESCE(SUM(?), 0)", d.distance),
      duration_min: fragment("COALESCE(SUM(?), 0)", d.duration_min),
      active_days: fragment("COUNT(DISTINCT date_trunc('day', ?))", d.start_date),
      short_trip_ratio:
        fragment(
          "COALESCE(AVG(CASE WHEN ? < 5 THEN 1.0 ELSE 0.0 END), 0)",
          d.distance
        ),
      night_trip_ratio:
        fragment(
          "COALESCE(AVG(CASE WHEN EXTRACT(HOUR FROM ?) >= 22 OR EXTRACT(HOUR FROM ?) < 6 THEN 1.0 ELSE 0.0 END), 0)",
          d.start_date,
          d.start_date
        ),
      weekend_ratio:
        fragment(
          "COALESCE(AVG(CASE WHEN EXTRACT(ISODOW FROM ?) >= 6 THEN 1.0 ELSE 0.0 END), 0)",
          d.start_date
        ),
      range_used:
        fragment(
          "COALESCE(SUM(GREATEST(COALESCE(?, 0) - COALESCE(?, 0), 0)), 0)",
          d.start_ideal_range_km,
          d.end_ideal_range_km
        )
    })
    |> Repo.one()
    |> then(fn stats ->
      distance = number(stats.distance)
      duration = number(stats.duration_min)
      range_used = number(stats.range_used)

      stats
      |> Map.put(:average_speed, if(duration > 0, do: distance / duration * 60, else: nil))
      |> Map.put(:average_trip, if(stats.count > 0, do: distance / stats.count, else: nil))
      |> Map.put(
        :consumption_wh_km,
        if(distance > 0 and is_number(car.efficiency),
          do: range_used * car.efficiency / distance * 1000,
          else: nil
        )
      )
    end)
  end

  defp analysis_charge_metrics(car_id, days) do
    ChargingProcess
    |> where([c], c.car_id == ^car_id and c.start_date >= ^since(days))
    |> select([c], %{
      count: count(c.id),
      energy: fragment("COALESCE(SUM(?), 0)", c.charge_energy_added),
      cost: fragment("COALESCE(SUM(?), 0)", c.cost),
      healthy_finish_ratio:
        fragment(
          "COALESCE(AVG(CASE WHEN ? IS NOT NULL AND ? <= 85 THEN 1.0 ELSE 0.0 END), 0)",
          c.end_battery_level,
          c.end_battery_level
        ),
      low_start_ratio:
        fragment(
          "COALESCE(AVG(CASE WHEN ? IS NOT NULL AND ? < 15 THEN 1.0 ELSE 0.0 END), 0)",
          c.start_battery_level,
          c.start_battery_level
        )
    })
    |> Repo.one()
  end

  defp scores(drive, charging) do
    efficiency =
      case drive.consumption_wh_km do
        value when is_number(value) -> clamp(round(112 - max(value - 140, 0) * 0.32), 35, 100)
        _ -> nil
      end

    usage =
      if drive.count > 0 do
        short = number(drive.short_trip_ratio)
        night = number(drive.night_trip_ratio)
        clamp(round(100 - short * 18 - night * 8), 55, 100)
      end

    charging_score =
      if charging.count > 0 do
        healthy = number(charging.healthy_finish_ratio)
        low_start = number(charging.low_start_ratio)
        clamp(round(60 + healthy * 40 - low_start * 10), 45, 100)
      end

    values = Enum.reject([efficiency, usage, charging_score], &is_nil/1)

    %{
      efficiency: efficiency,
      usage: usage,
      charging: charging_score,
      overall: if(values == [], do: nil, else: round(Enum.sum(values) / length(values)))
    }
  end

  defp recommendations(drive, charging, scores) do
    []
    |> maybe_recommend(
      drive.count == 0,
      "当前时间范围没有完整行程，扩大时间范围后才能生成驾驶分析。"
    )
    |> maybe_recommend(
      number(drive.short_trip_ratio) >= 0.45,
      "短途行程占比较高，可合并相邻出行，减少频繁唤醒和空调预热带来的额外耗电。"
    )
    |> maybe_recommend(
      number(drive.night_trip_ratio) >= 0.3,
      "夜间出行比例较高，请优先保证充足休息；本评分不等同于驾驶安全评估。"
    )
    |> maybe_recommend(
      is_number(drive.consumption_wh_km) and drive.consumption_wh_km > 220,
      "近期估算能耗偏高，可检查胎压、空调使用、低温和高速行驶占比。"
    )
    |> maybe_recommend(
      charging.count > 0 and number(charging.healthy_finish_ratio) < 0.6,
      "多数充电会话结束电量高于 85%。非长途出发时，可考虑降低日常充电上限。"
    )
    |> maybe_recommend(
      charging.count > 0 and number(charging.low_start_ratio) > 0.25,
      "低于 15% 才开始充电的比例较高，条件允许时可提前补能，减少里程焦虑。"
    )
    |> maybe_recommend(
      not is_nil(scores.overall) and scores.overall >= 85,
      "近期用车与充电模式整体稳定，请继续结合实际路况和车辆手册判断。"
    )
    |> Enum.reverse()
  end

  defp maybe_recommend(items, true, message), do: [message | items]
  defp maybe_recommend(items, false, _message), do: items

  defp live_summary(car_id) do
    Vehicles.list() |> Enum.find(fn summary -> summary.car.id == car_id end)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp empty_report(cars), do: %{cars: cars, car: nil, live: nil, position: nil}

  defp average_field(rows, field) do
    values = rows |> Enum.map(&number(Map.get(&1, field))) |> Enum.filter(&is_number/1)
    if values == [], do: nil, else: Enum.sum(values) / length(values)
  end

  defp number(nil), do: 0.0
  defp number(%Decimal{} = value), do: Decimal.to_float(value)
  defp number(value) when is_integer(value), do: value * 1.0
  defp number(value) when is_float(value), do: value
  defp number(_), do: 0.0

  defp normalize_days(days) when is_integer(days) and days in @allowed_ranges, do: days

  defp normalize_days(days) when is_binary(days) do
    case Integer.parse(days) do
      {value, ""} when value in @allowed_ranges -> value
      _ -> 30
    end
  end

  defp normalize_days(_), do: 30

  defp since(days), do: DateTime.add(DateTime.utc_now(), -days, :day)
  defp clamp(value, minimum, maximum), do: value |> max(minimum) |> min(maximum)

  defp parse_id(value) when is_integer(value), do: value

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> -1
    end
  end

  defp parse_id(_), do: -1
end
