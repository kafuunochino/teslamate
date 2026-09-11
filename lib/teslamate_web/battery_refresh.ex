defmodule TeslaMateWeb.BatteryRefresh do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]
  require Logger

  def attach(socket, page) when page in [:battery, :charging] do
    socket
    |> assign(
      battery_page: page,
      battery_timer: nil,
      battery_token: nil,
      battery_visible?: true,
      battery_error: false,
      battery_aggregate_at: DateTime.utc_now()
    )
    |> attach_hook(:battery_timer, :handle_info, &handle_info/2)
    |> attach_hook(:battery_visibility, :handle_event, &handle_event/3)
  end

  def schedule(socket) do
    if socket.assigns.battery_timer, do: Process.cancel_timer(socket.assigns.battery_timer)

    if connected?(socket) and socket.assigns.battery_visible? do
      token = make_ref()
      timer = Process.send_after(self(), {:battery_refresh, token}, 5_000)
      assign(socket, battery_timer: timer, battery_token: token)
    else
      assign(socket, battery_timer: nil, battery_token: nil)
    end
  end

  defp handle_info({:battery_refresh, token}, socket) do
    if token == socket.assigns.battery_token and not is_nil(token) do
      {:halt, socket |> refresh(false) |> schedule()}
    else
      {:halt, socket}
    end
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  defp handle_event("refresh_battery", _params, socket),
    do: {:halt, socket |> refresh(true) |> schedule()}

  defp handle_event("visibility", %{"visible" => visible}, socket) when is_boolean(visible) do
    socket = assign(socket, battery_visible?: visible)
    socket = if visible, do: refresh(socket, false), else: socket
    {:halt, schedule(socket)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp refresh(socket, force) do
    now = DateTime.utc_now()
    full? = force or DateTime.diff(now, socket.assigns.battery_aggregate_at) >= 60
    previous = socket.assigns.report

    report =
      if previous do
        TeslaMate.Fleet.refresh_battery(
          socket.assigns.current_user,
          previous,
          socket.assigns.battery_page,
          full?
        )
      else
        apply(TeslaMate.Fleet, socket.assigns.battery_page, [socket.assigns.current_user, nil])
      end

    socket =
      if socket.assigns.battery_page == :charging and
           (is_nil(previous) or previous.car != report.car) do
        assign(socket, editing_charge: nil, cost_changeset: nil, cost_notice: nil)
      else
        socket
      end

    socket = assign(socket, report: report, battery_error: false)
    if full?, do: assign(socket, battery_aggregate_at: now), else: socket
  rescue
    error ->
      Logger.warning("Battery dashboard refresh failed (#{inspect(error.__struct__)})")
      # Do not retain private readings if access cannot be rechecked.
      assign(socket, report: nil, battery_error: true)
  end
end
