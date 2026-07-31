defmodule TeslaMateWeb.DashboardLive.Trip do
  use TeslaMateWeb, :live_view

  alias TeslaMate.Fleet

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Fleet.trip(socket.assigns.current_user, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "行程不存在或你没有访问权限")
         |> redirect(to: Routes.dashboard_path(socket, :trips))}

      report ->
        points = downsample(report.positions, 700)

        {:ok,
         assign(socket,
           page_title: "行程详情",
           report: report,
           map_points: Jason.encode!(points)
         )}
    end
  end

  defp downsample(points, maximum) when length(points) <= maximum, do: points

  defp downsample(points, maximum) do
    step = max(div(length(points) + maximum - 1, maximum), 1)
    sampled = points |> Enum.with_index() |> Enum.filter(fn {_point, index} -> rem(index, step) == 0 end) |> Enum.map(&elem(&1, 0))
    Enum.uniq_by(sampled ++ [List.last(points)], &{&1.latitude, &1.longitude, &1.date})
  end
end
