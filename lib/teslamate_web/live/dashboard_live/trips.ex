defmodule TeslaMateWeb.DashboardLive.Trips do
  use TeslaMateWeb, :live_view

  alias TeslaMate.Fleet

  @impl true
  def mount(params, _session, socket) do
    report = load_report(socket, params)
    {:ok, assign(socket, page_title: "行程轨迹", report: report)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    report = load_report(socket, params)
    {:noreply, assign(socket, report: report)}
  end

  @impl true
  def handle_event("select_vehicle", %{"vehicle" => %{"id" => id}}, socket) do
    {:noreply,
     push_patch(socket,
       to: Routes.dashboard_path(socket, :trips, car: id, days: socket.assigns.report.days)
     )}
  end

  def handle_event("select_range", %{"days" => days}, socket) do
    car_id = socket.assigns.report.car && socket.assigns.report.car.id

    {:noreply,
     push_patch(socket, to: Routes.dashboard_path(socket, :trips, car: car_id, days: days))}
  end

  defp load_report(socket, params) do
    Fleet.trips(
      socket.assigns.current_user,
      params["car"],
      params["days"] || 30,
      params["page"] || 1
    )
  end

  defp pagination_links(%{page: page, total_pages: total_pages}) do
    [
      {"first", "首页", 1, page == 1},
      {"previous", "上一页", page - 1, page == 1},
      {"next", "下一页", page + 1, page == total_pages},
      {"last", "末页", total_pages, page == total_pages}
    ]
  end

  defp page_path(socket, report, page) do
    Routes.dashboard_path(socket, :trips, car: report.car.id, days: report.days, page: page) <>
      "#trip-list"
  end
end
