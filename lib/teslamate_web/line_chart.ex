defmodule TeslaMateWeb.LineChart do
  use Phoenix.Component

  import TeslaMateWeb.PlatformComponents, only: [format_number: 2, date_time: 1]

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :unit, :string, default: ""
  attr :precision, :integer, default: 1
  attr :period, :string, default: "day"
  attr :max_gap, :integer, default: 86_400
  attr :zero, :boolean, default: false
  attr :tone, :string, default: "blue"
  attr :empty, :string, default: "当前时间范围暂无数据"
  attr :note, :string, default: nil

  def chart(assigns) do
    chart = geometry(assigns.rows, assigns.max_gap, assigns.zero)

    points =
      Enum.map(chart.points, fn point ->
        Map.merge(point, %{
          label: period_label(point.period, assigns.period),
          short_label: short_label(point.period, assigns.period),
          formatted: format_number(point.value, assigns.precision) <> assigns.unit
        })
        |> Map.delete(:period)
      end)

    assigns = assign(assigns, chart: chart, points: points, latest: List.last(points))

    ~H"""
    <section
      id={@id}
      class={["data-card", "line-chart", "line-chart--#{@tone}"]}
      phx-hook="LineChart"
      data-points={Jason.encode!(@points)}
    >
      <div class="data-card__header">
        <h2 id={@id <> "-title"}><%= @title %></h2>
        <span><%= String.trim(@unit) %></span>
      </div>
      <div :if={!@latest} class="empty-inline"><%= @empty %></div>
      <%= if @latest do %>
        <div class="line-chart__readout" aria-live="polite" aria-atomic="true">
          <span data-chart-label><%= @latest.label %></span>
          <strong data-chart-value><%= @latest.formatted %></strong>
        </div>
        <div class="line-chart__body">
          <div class="line-chart__scale" aria-hidden="true">
            <span :for={tick <- @chart.ticks}><%= format_number(tick, @precision) %></span>
          </div>
          <div
            class="line-chart__plot"
            tabindex="0"
            role="group"
            aria-labelledby={@id <> "-title"}
            aria-describedby={@id <> "-help"}
            data-chart-plot
          >
            <svg viewBox="0 0 720 200" preserveAspectRatio="none" aria-hidden="true">
              <path d="M0 0H720 M0 50H720 M0 100H720 M0 150H720 M0 200H720" class="line-chart__grid" />
              <path d={@chart.path} class="line-chart__curve" />
              <circle
                :for={point <- @points}
                cx={point.x}
                cy={point.y}
                r={if length(@points) > 90, do: 1.5, else: 3}
                class="line-chart__point"
              />
              <line
                data-chart-guide
                x1={@latest.x}
                x2={@latest.x}
                y1="0"
                y2="200"
                class="line-chart__guide"
              />
            </svg>
            <span
              data-chart-marker
              class="line-chart__marker"
              style={"left: #{@latest.x / 720 * 100}%; top: #{@latest.y / 200 * 100}%"}
            >
            </span>
            <div data-chart-tooltip class="line-chart__tooltip" hidden aria-hidden="true">
              <span data-tooltip-label></span><strong data-tooltip-value></strong>
            </div>
          </div>
          <div class="line-chart__dates" aria-hidden="true">
            <span :for={point <- axis_points(@points)} style={"left: #{point.x / 720 * 100}%"}>
              <%= point.short_label %>
            </span>
          </div>
        </div>
        <p id={@id <> "-help"} class="line-chart__help">移动鼠标或触摸曲线查看数值 · 键盘 ← → 切换采样点</p>
      <% end %>
      <p :if={@note} class="line-chart__note"><%= @note %></p>
    </section>
    """
  end

  # Keep missing samples as gaps; zero is a real reading, never a missing value.
  def geometry(rows, max_gap, zero) do
    rows =
      rows
      |> Enum.map(fn row ->
        Map.merge(row, %{time: timestamp(row.period), value: numeric(row.value)})
      end)
      |> Enum.sort_by(& &1.time)
      |> Enum.reverse()
      |> Enum.uniq_by(& &1.time)
      |> Enum.reverse()

    values = for row <- rows, is_number(row.value), do: row.value
    minimum = Enum.min(values, fn -> 0.0 end)
    maximum = Enum.max(values, fn -> 0.0 end)
    low = if zero, do: min(minimum, 0), else: minimum
    high = if zero, do: max(maximum, 0), else: maximum
    padding = if high == low, do: max(abs(high) * 0.05, 1), else: (high - low) * 0.1
    low = low - padding
    high = high + padding
    start = if rows == [], do: 0, else: hd(rows).time
    finish = if rows == [], do: 0, else: List.last(rows).time

    {points, parts, _previous} =
      Enum.reduce(rows, {[], [], nil}, fn row, {points, parts, previous} ->
        if is_number(row.value) do
          x =
            if start == finish, do: 360.0, else: 12 + (row.time - start) / (finish - start) * 696

          y = 200 - (row.value - low) / (high - low) * 200
          point = Map.merge(row, %{x: Float.round(x, 2), y: Float.round(y, 2)})

          part =
            if previous && row.time - previous.time <= max_gap do
              middle = Float.round((previous.x + point.x) / 2, 2)
              # Horizontal controls keep the curve inside the two measured values.
              "C#{middle} #{previous.y} #{middle} #{point.y} #{point.x} #{point.y}"
            else
              "M#{point.x} #{point.y}"
            end

          {[point | points], [part | parts], point}
        else
          {points, parts, nil}
        end
      end)

    %{
      points: Enum.reverse(points),
      path: parts |> Enum.reverse() |> Enum.join(" "),
      ticks: for(index <- 0..4, do: high - (high - low) * index / 4)
    }
  end

  defp axis_points(points) do
    last = length(points) - 1
    [0, round(last / 2), last] |> Enum.uniq() |> Enum.map(&Enum.at(points, &1))
  end

  defp numeric(%Decimal{} = value), do: Decimal.to_float(value)
  defp numeric(value) when is_number(value), do: value * 1.0
  defp numeric(_value), do: nil

  defp timestamp(%Date{} = value), do: Date.diff(value, ~D[1970-01-01]) * 86_400

  defp timestamp(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> timestamp()

  defp timestamp(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond) / 1000

  defp period_label(value, "time"),
    do: date_time(value) <> Calendar.strftime(local_time(value), ":%S")

  defp period_label(value, "month"), do: Calendar.strftime(value, "%Y-%m")
  defp period_label(value, _period), do: Calendar.strftime(value, "%Y-%m-%d")
  defp short_label(value, "time"), do: Calendar.strftime(local_time(value), "%H:%M")
  defp short_label(value, "month"), do: Calendar.strftime(value, "%Y-%m")
  defp short_label(value, _period), do: Calendar.strftime(value, "%m/%d")

  defp local_time(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> local_time()

  defp local_time(%DateTime{} = value), do: DateTime.shift_zone!(value, "Asia/Shanghai")
end
