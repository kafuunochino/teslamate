defmodule TeslaMateWeb.DashboardLive.Driving do
  use TeslaMateWeb, :live_view

  require Logger
  alias TeslaMate.Fleet
  import TeslaMateWeb.BatteryComponents

  @intervals [0, 1, 2, 5, 10, 30, 60]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "行车仪表盘",
       report: nil,
       refresh_interval: 5,
       requested_car: nil,
       refresh_timer: nil,
       refresh_token: nil,
       visible?: true,
       refreshed_at: nil,
       refresh_error: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(
        requested_car: params["car"],
        refresh_interval: normalize_interval(params["refresh"])
      )
      |> refresh()
      |> schedule_refresh()

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_refresh_interval", %{"refresh" => %{"seconds" => seconds}}, socket) do
    params = [car: selected_car(socket), refresh: normalize_interval(seconds)]
    {:noreply, push_patch(socket, to: Routes.dashboard_path(socket, :driving, params))}
  end

  def handle_event("select_vehicle", %{"vehicle" => %{"id" => id}}, socket) do
    params = [car: id, refresh: socket.assigns.refresh_interval]
    {:noreply, push_patch(socket, to: Routes.dashboard_path(socket, :driving, params))}
  end

  def handle_event("refresh", _params, socket) do
    # An explicit refresh also incorporates any enriched historical samples.
    {:noreply, socket |> assign(report: nil) |> refresh() |> schedule_refresh()}
  end

  def handle_event("visibility", %{"visible" => visible}, socket) when is_boolean(visible) do
    socket = assign(socket, visible?: visible)
    socket = if visible and socket.assigns.refresh_interval > 0, do: refresh(socket), else: socket
    {:noreply, schedule_refresh(socket)}
  end

  @impl true
  def handle_info({:refresh, token}, %{assigns: %{refresh_token: token}} = socket)
      when not is_nil(token) do
    {:noreply, socket |> refresh() |> schedule_refresh()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    cancel_timer(socket.assigns[:refresh_timer])
    :ok
  end

  def normalize_interval(value) when value in @intervals, do: value

  def normalize_interval(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds in @intervals -> seconds
      _ -> 5
    end
  end

  def normalize_interval(_value), do: 5

  defp selected_car(%{assigns: %{report: %{car: %{id: id}}}}), do: id
  defp selected_car(_socket), do: nil

  defp refresh(socket) do
    previous =
      case socket.assigns.report do
        %{driving_stats: stats} -> stats
        _ -> nil
      end

    report = Fleet.driving(socket.assigns.current_user, socket.assigns.requested_car, previous)

    assign(socket,
      report: report,
      refreshed_at: DateTime.utc_now(),
      refresh_error: false
    )
  rescue
    error ->
      Logger.warning("Driving dashboard refresh failed (#{inspect(error.__struct__)})")

      # Clear telemetry if authorization or storage cannot be rechecked.
      assign(socket, report: nil, refresh_error: true)
  end

  defp schedule_refresh(socket) do
    cancel_timer(socket.assigns.refresh_timer)
    interval = socket.assigns.refresh_interval

    if connected?(socket) and socket.assigns.visible? and interval > 0 do
      token = make_ref()
      timer = Process.send_after(self(), {:refresh, token}, interval * 1000)
      assign(socket, refresh_timer: timer, refresh_token: token)
    else
      assign(socket, refresh_timer: nil, refresh_token: nil)
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp telemetry_time(report) do
    dates = [
      report.live && report.live.data_updated_at,
      report.position && report.position.date
    ]

    dates
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max_by(&DateTime.to_unix(&1, :millisecond), fn -> nil end)
  end

  defp fresh?(report, now) do
    with %{healthy: true, state: state} <- report.live,
         true <- state in [:online, :driving, :charging],
         %DateTime{} = date <- telemetry_time(report) do
      DateTime.diff(now, date) in -5..30
    else
      _ -> false
    end
  end

  defp reading(report, key) do
    live = report.live && Map.get(report.live, key)
    stored = report.position && Map.get(report.position, key)

    stored_newer =
      report.position && report.live && report.live.data_updated_at &&
        DateTime.compare(report.position.date, report.live.data_updated_at) == :gt

    cond do
      stored_newer && not is_nil(stored) -> stored
      is_nil(live) -> stored
      true -> live
    end
  end

  defp current_reading(report, key, fresh) do
    if fresh, do: reading(report, key)
  end

  defp instant_consumption(report, fresh) do
    speed = current_reading(report, :speed, fresh)
    power = current_reading(report, :power, fresh)
    if is_number(speed) and speed >= 10 and is_number(power), do: power * 1000 / speed
  end

  defp signed(nil, _unit), do: "—"

  defp signed(value, unit) do
    prefix = if value > 0, do: "+", else: ""
    prefix <> format_number(value, 1) <> unit
  end

  defp scalar(nil, _unit, _precision), do: "—"
  defp scalar(value, unit, precision), do: format_number(value, precision) <> unit

  defp heading(nil), do: "—"

  defp heading(value) when is_number(value) do
    direction = Enum.at(["北", "东北", "东", "东南", "南", "西南", "西", "西北"], rem(round(value / 45), 8))
    "#{direction} · #{round(value)}°"
  end

  defp heading(_value), do: "—"
  defp iso(nil), do: ""
  defp iso(date), do: DateTime.to_iso8601(date)

  attr :title, :string, required: true
  attr :trail, :list, required: true
  attr :field, :atom, required: true
  attr :unit, :string, required: true
  attr :tone, :string, default: "blue"

  defp trend_chart(assigns) do
    rows = Enum.reverse(assigns.trail)
    values = Enum.map(rows, &Map.get(&1, assigns.field)) |> Enum.filter(&is_number/1)
    minimum = Enum.min(values, fn -> 0 end)
    maximum = Enum.max(values, fn -> 0 end)
    low = if assigns.field == :power, do: min(minimum, 0), else: minimum
    high = if assigns.field == :power, do: max(maximum, 0), else: maximum
    start = if rows == [], do: 0, else: DateTime.to_unix(hd(rows).date, :millisecond)
    finish = if rows == [], do: 0, else: DateTime.to_unix(List.last(rows).date, :millisecond)

    {segments, _previous} =
      Enum.reduce(rows, {[], nil}, fn row, {segments, previous} ->
        value = Map.get(row, assigns.field)

        if is_number(value) do
          x =
            8 + (DateTime.to_unix(row.date, :millisecond) - start) / max(finish - start, 1) * 584

          y = 130 - (value - low) / max(high - low, 1) * 118
          point = "#{Float.round(x, 1)},#{Float.round(y, 1)}"

          if previous && DateTime.diff(row.date, previous.date) <= 30 && segments != [] do
            [segment | rest] = segments
            {[[point | segment] | rest], row}
          else
            {[[point] | segments], row}
          end
        else
          {segments, nil}
        end
      end)

    assigns =
      assign(assigns,
        points:
          segments
          |> Enum.filter(&(length(&1) > 1))
          |> Enum.map(&(Enum.reverse(&1) |> Enum.join(" "))),
        minimum: if(values != [], do: minimum),
        maximum: if(values != [], do: maximum)
      )

    ~H"""
    <section class={["data-card", "drive-trend", "drive-trend--#{@tone}"]}>
      <div class="data-card__header">
        <h2><%= @title %></h2>
        <span><%= scalar(@minimum, @unit, 0) %> ～ <%= scalar(@maximum, @unit, 0) %></span>
      </div>
      <svg
        :if={@points != []}
        viewBox="0 0 600 140"
        preserveAspectRatio="none"
        role="img"
        aria-label={@title}
      >
        <path d="M8 12H592 M8 71H592 M8 130H592" class="drive-trend__grid" />
        <polyline :for={points <- @points} points={points} fill="none" class="drive-trend__line" />
      </svg>
      <div :if={@points == []} class="empty-inline">等待连续采样数据</div>
      <p>该行程最近 20 分钟内的采样，缺失时段留空。</p>
    </section>
    """
  end
end
