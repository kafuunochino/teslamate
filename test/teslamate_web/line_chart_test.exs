defmodule TeslaMateWeb.LineChartTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias TeslaMateWeb.LineChart

  test "orders samples in time and preserves their measured values" do
    rows = [
      %{period: ~D[2026-09-03], value: Decimal.new("62.47")},
      %{period: ~D[2026-09-01], value: 61.12},
      %{period: ~D[2026-09-02], value: 63.01}
    ]

    chart = LineChart.geometry(rows, 86_400, false)
    assert Enum.map(chart.points, & &1.value) == [61.12, 63.01, 62.47]
    assert Enum.map(chart.points, & &1.x) == [12.0, 360.0, 708.0]
    assert length(Regex.scan(~r/C/, chart.path)) == 2
    assert Enum.all?(chart.points, &(&1.y >= 0 and &1.y <= 200))
  end

  test "missing readings and long time gaps do not create invented curves or zero values" do
    rows = [
      %{period: ~U[2026-09-21 01:00:00Z], value: 0},
      %{period: ~U[2026-09-21 01:00:05Z], value: -12},
      %{period: ~U[2026-09-21 01:00:10Z], value: nil},
      %{period: ~U[2026-09-21 01:00:15Z], value: 18},
      %{period: ~U[2026-09-21 01:01:15Z], value: 22}
    ]

    chart = LineChart.geometry(rows, 30, true)
    assert Enum.map(chart.points, & &1.value) == [0.0, -12.0, 18.0, 22.0]
    assert length(Regex.scan(~r/M/, chart.path)) == 3
    assert length(Regex.scan(~r/C/, chart.path)) == 1
    assert List.last(chart.ticks) < -12
    assert hd(chart.ticks) > 22
  end

  test "empty, single and constant samples remain readable" do
    assert LineChart.geometry([], 86_400, false).points == []
    assert LineChart.geometry([%{period: ~D[2026-09-01], value: nil}], 86_400, false).points == []

    single = LineChart.geometry([%{period: ~D[2026-09-01], value: 0}], 86_400, false)
    assert [%{x: 360.0, y: 100.0, value: 0.0}] = single.points

    constant = LineChart.geometry(for(day <- 1..3, do: %{period: Date.new!(2026, 9, day), value: 62}), 86_400, false)
    assert Enum.all?(constant.points, &(&1.y == 100.0))
  end

  test "renders values, units, axes and keyboard instructions without requiring JavaScript" do
    html = render_component(&LineChart.chart/1,
      id: "battery-chart",
      title: "每日满电能量估算",
      rows: [%{period: ~D[2026-09-21], value: Decimal.new("62.47")}],
      precision: 2,
      unit: " kWh"
    )

    assert html =~ "62.47 kWh"
    assert html =~ "2026-09-21"
    assert html =~ ~s(phx-hook="LineChart")
    assert html =~ ~s(tabindex="0")
    assert html =~ "键盘 ← →"
    assert html =~ "line-chart__point"
    refute html =~ "bar-chart"
  end

  test "sample timestamps are shown in Beijing time" do
    html = render_component(&LineChart.chart/1,
      id: "power-chart",
      title: "耗电与回收功率",
      rows: [%{period: ~U[2026-09-20 16:00:05Z], value: -8.5}],
      period: "time",
      unit: " kW"
    )

    assert html =~ "2026-09-21 00:00:05"
    assert html =~ "-8.5 kW"
  end

  test "empty charts display their empty state without an interactive plot" do
    html = render_component(&LineChart.chart/1,
      id: "empty-chart", title: "电池", rows: [], empty: "缺少有效样本"
    )

    assert html =~ "缺少有效样本"
    refute html =~ "data-chart-plot"
  end
end
