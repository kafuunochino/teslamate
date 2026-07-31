defmodule TeslaMateWeb.DashboardLive.Home do
  use TeslaMateWeb, :live_view

  alias TeslaMate.Fleet
  alias TeslaMate.Vehicles
  alias TeslaMate.Vehicles.Vehicle.Summary

  @impl true
  def mount(params, _session, socket) do
    report = Fleet.home(socket.assigns.current_user, params["car"])

    if connected?(socket) and report.car do
      Vehicles.subscribe_to_summary(report.car.id)
    end

    {:ok, assign(socket, page_title: "首页", report: report)}
  end

  @impl true
  def handle_event("select_vehicle", %{"vehicle" => %{"id" => id}}, socket) do
    {:noreply, push_navigate(socket, to: Routes.dashboard_path(socket, :home, car: id))}
  end

  @impl true
  def handle_info(%Summary{car: %{id: id}} = summary, %{assigns: %{report: %{car: %{id: id}}}} = socket) do
    {:noreply, update(socket, :report, &Map.put(&1, :live, summary))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
