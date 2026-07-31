defmodule TeslaMateWeb.DashboardLive.Battery do
  use TeslaMateWeb, :live_view

  alias TeslaMate.Fleet

  @impl true
  def mount(params, _session, socket) do
    report = Fleet.battery(socket.assigns.current_user, params["car"], params["days"] || 90)
    {:ok, assign(socket, page_title: "电池", report: report)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    report = Fleet.battery(socket.assigns.current_user, params["car"], params["days"] || 90)
    {:noreply, assign(socket, report: report)}
  end

  @impl true
  def handle_event("select_vehicle", %{"vehicle" => %{"id" => id}}, socket) do
    {:noreply,
     push_patch(socket,
       to: Routes.dashboard_path(socket, :battery, car: id, days: socket.assigns.report.days)
     )}
  end

  def handle_event("select_range", %{"days" => days}, socket) do
    car_id = socket.assigns.report.car && socket.assigns.report.car.id
    {:noreply, push_patch(socket, to: Routes.dashboard_path(socket, :battery, car: car_id, days: days))}
  end
end
