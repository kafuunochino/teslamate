defmodule TeslaMate.DrivingStats do
  @moduledoc """
  Incremental estimates from recorded driving samples. Missing intervals are not
  extrapolated; only intervals of at most 30 seconds contribute to energy totals.
  """

  defstruct drive_id: nil,
            last_id: 0,
            first: nil,
            last: nil,
            samples: 0,
            energy_used: 0.0,
            energy_recovered: 0.0,
            covered_seconds: 0.0,
            ascent: 0.0,
            descent: 0.0,
            altitude_intervals: 0,
            altitude_min: nil,
            altitude_max: nil,
            trail: []

  def new(drive_id), do: %__MODULE__{drive_id: drive_id}

  def append(%__MODULE__{} = stats, position) do
    point =
      Map.new([:id, :date, :elevation, :power, :odometer, :rated_battery_range_km], fn key ->
        value = Map.get(position, key)
        {key, if(match?(%Decimal{}, value), do: Decimal.to_float(value), else: value)}
      end)

    cond do
      point.id <= stats.last_id ->
        stats

      stats.last && DateTime.compare(point.date, stats.last.date) == :lt ->
        %{stats | last_id: point.id}

      true ->
        stats
        |> integrate(point)
        |> Map.merge(%{
          first: stats.first || point,
          last: point,
          last_id: point.id,
          samples: stats.samples + 1,
          altitude_min: minimum(stats.altitude_min, point.elevation),
          altitude_max: maximum(stats.altitude_max, point.elevation),
          trail: sample_trail(stats.trail, point)
        })
    end
  end

  def metrics(%__MODULE__{first: nil}), do: empty_metrics()

  def metrics(%__MODULE__{} = stats) do
    elapsed = max(0, DateTime.diff(stats.last.date, stats.first.date, :millisecond) / 1000)
    distance = difference(stats.last.odometer, stats.first.odometer)
    distance = if is_number(distance) and distance >= 0, do: distance
    range_used = difference(stats.first.rated_battery_range_km, stats.last.rated_battery_range_km)
    energy = if stats.covered_seconds > 0, do: stats.energy_used - stats.energy_recovered

    %{
      distance: distance,
      duration_min: elapsed / 60,
      average_speed: if(is_number(distance) and elapsed > 0, do: distance * 3600 / elapsed),
      energy_used: if(stats.covered_seconds > 0, do: stats.energy_used),
      energy_recovered: if(stats.covered_seconds > 0, do: stats.energy_recovered),
      net_energy: energy,
      consumption: if(is_number(energy) and is_number(distance) and distance >= 1, do: energy * 1000 / distance),
      recovery_ratio: if(stats.energy_used > 0.01, do: stats.energy_recovered / stats.energy_used * 100),
      coverage: if(elapsed > 0, do: min(100.0, stats.covered_seconds / elapsed * 100)),
      ascent: if(stats.altitude_intervals > 0, do: stats.ascent),
      descent: if(stats.altitude_intervals > 0, do: stats.descent),
      altitude_min: stats.altitude_min,
      altitude_max: stats.altitude_max,
      altitude_change: difference(stats.last.elevation, stats.first.elevation),
      range_used: range_used,
      range_efficiency: if(is_number(distance) and distance >= 1 and is_number(range_used) and range_used >= 0.5, do: distance / range_used * 100),
      grade: grade(stats)
    }
  end

  defp integrate(%{last: nil} = stats, _point), do: stats

  defp integrate(stats, point) do
    previous = stats.last
    seconds = DateTime.diff(point.date, previous.date, :millisecond) / 1000

    if seconds > 0 and seconds <= 30 do
      stats =
        if is_number(previous.power) and is_number(point.power) do
          {used, recovered} = energy_between(previous.power, point.power, seconds)

          %{stats |
            energy_used: stats.energy_used + used,
            energy_recovered: stats.energy_recovered + recovered,
            covered_seconds: stats.covered_seconds + seconds
          }
        else
          stats
        end

      if is_number(previous.elevation) and is_number(point.elevation) do
        delta = point.elevation - previous.elevation

        %{stats |
          ascent: stats.ascent + max(delta, 0),
          descent: stats.descent + max(-delta, 0),
          altitude_intervals: stats.altitude_intervals + 1
        }
      else
        stats
      end
    else
      stats
    end
  end

  defp energy_between(a, b, seconds) when a >= 0 and b >= 0,
    do: {(a + b) / 2 * seconds / 3600, 0.0}

  defp energy_between(a, b, seconds) when a <= 0 and b <= 0,
    do: {0.0, -(a + b) / 2 * seconds / 3600}

  defp energy_between(a, b, seconds) do
    # Split a sign-changing interval at zero to retain both draw and recovery.
    crossing = seconds * abs(a) / (abs(a) + abs(b))
    first = abs(a) * crossing / 2 / 3600
    second = abs(b) * (seconds - crossing) / 2 / 3600
    if a > 0, do: {first, second}, else: {second, first}
  end

  defp sample_trail([previous | rest] = trail, point) do
    if div(DateTime.to_unix(previous.date), 10) == div(DateTime.to_unix(point.date), 10) do
      [point | rest]
    else
      [point | trail]
      |> Enum.take_while(&(DateTime.diff(point.date, &1.date) <= 1200))
      |> Enum.take(120)
    end
  end

  defp sample_trail([], point), do: [point]

  defp grade(%{last: %{odometer: odometer, elevation: elevation} = latest, trail: trail})
       when is_number(odometer) and is_number(elevation) do
    trail
    |> Enum.filter(fn point ->
      is_number(point.odometer) and is_number(point.elevation) and
        odometer - point.odometer >= 0.05 and odometer - point.odometer <= 0.3 and
        DateTime.diff(latest.date, point.date) in 1..120
    end)
    |> Enum.min_by(fn point -> abs(odometer - point.odometer - 0.1) end, fn -> nil end)
    |> case do
      nil -> nil
      point ->
        meters = (odometer - point.odometer) * 1000
        %{percent: (elevation - point.elevation) / meters * 100, meters: round(meters)}
    end
  end

  defp grade(_stats), do: nil

  defp difference(a, b) when is_number(a) and is_number(b), do: a - b
  defp difference(_, _), do: nil
  defp minimum(nil, value), do: value
  defp minimum(value, nil), do: value
  defp minimum(a, b), do: min(a, b)
  defp maximum(nil, value), do: value
  defp maximum(value, nil), do: value
  defp maximum(a, b), do: max(a, b)

  defp empty_metrics do
    Map.new([
      :distance, :duration_min, :average_speed, :energy_used, :energy_recovered,
      :net_energy, :consumption, :recovery_ratio, :coverage, :ascent, :descent,
      :altitude_min, :altitude_max, :altitude_change, :range_used, :range_efficiency, :grade
    ], &{&1, nil})
  end
end
