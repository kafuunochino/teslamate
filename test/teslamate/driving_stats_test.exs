defmodule TeslaMate.DrivingStatsTest do
  use ExUnit.Case, async: true

  alias TeslaMate.DrivingStats

  defp point(id, seconds, attrs \\ %{}) do
    Map.merge(%{
      id: id, date: DateTime.add(~U[2026-01-01 00:00:00Z], seconds),
      elevation: 100, power: 36, odometer: 1000 + seconds / 100,
      rated_battery_range_km: 300 - seconds / 10
    }, attrs)
  end

  test "splits sign-changing power into consumption and recovery" do
    stats =
      DrivingStats.new(1)
      |> DrivingStats.append(point(1, 0))
      |> DrivingStats.append(point(2, 10, %{power: -36, elevation: 110}))
      |> DrivingStats.append(point(3, 20, %{power: -36, elevation: 105}))

    metrics = DrivingStats.metrics(stats)
    assert_in_delta metrics.energy_used, 0.025, 0.000001
    assert_in_delta metrics.energy_recovered, 0.125, 0.000001
    assert_in_delta metrics.net_energy, -0.1, 0.000001
    assert metrics.ascent == 10
    assert metrics.descent == 5
    assert metrics.altitude_change == 5
    assert metrics.coverage == 100
  end

  test "does not extrapolate missing power or long gaps" do
    stats =
      DrivingStats.new(1)
      |> DrivingStats.append(point(1, 0))
      |> DrivingStats.append(point(2, 60, %{power: nil}))
      |> DrivingStats.append(point(3, 70))

    metrics = DrivingStats.metrics(stats)
    assert metrics.net_energy == nil
    assert metrics.energy_recovered == nil
    assert metrics.coverage == 0
  end

  test "incremental reads do not double count or reverse time" do
    first = point(1, 0)
    last = point(2, 10)
    stats = DrivingStats.new(1) |> DrivingStats.append(first) |> DrivingStats.append(last)
    assert DrivingStats.append(stats, last) == stats

    stats = DrivingStats.append(stats, point(3, 5))
    assert stats.last_id == 3
    assert stats.last.date == last.date
    assert_in_delta DrivingStats.metrics(stats).net_energy, 0.1, 0.000001
  end

  test "calculates grade across a meaningful distance window" do
    stats =
      Enum.reduce(0..3, DrivingStats.new(1), fn i, acc ->
        DrivingStats.append(acc, point(i + 1, i * 10, %{odometer: 1000 + i * 0.05, elevation: 100 + i * 5}))
      end)

    assert %{grade: %{meters: 100, percent: grade}} = DrivingStats.metrics(stats)
    assert_in_delta grade, 10, 0.000001
  end

  test "bounds the chart history and retains zero altitude" do
    stats =
      Enum.reduce(0..200, DrivingStats.new(1), fn i, acc ->
        DrivingStats.append(acc, point(i + 1, i * 10, %{elevation: 0}))
      end)

    assert length(stats.trail) == 120
    assert DrivingStats.metrics(stats).altitude_min == 0

    stats = DrivingStats.append(stats, point(202, 4000))
    assert length(stats.trail) == 1
  end

  test "unknown and very short measurements are not fabricated as efficiency" do
    metrics = DrivingStats.new(1) |> DrivingStats.metrics()
    assert metrics.net_energy == nil
    assert metrics.altitude_min == nil

    metrics =
      DrivingStats.new(1)
      |> DrivingStats.append(point(1, 0))
      |> DrivingStats.append(point(2, 10))
      |> DrivingStats.metrics()

    assert metrics.consumption == nil
    assert metrics.range_efficiency == nil
  end
end
