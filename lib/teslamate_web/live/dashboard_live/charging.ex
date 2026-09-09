defmodule TeslaMateWeb.DashboardLive.Charging do
  use TeslaMateWeb, :live_view

  alias TeslaMate.{ChargeCosts, Fleet}
  alias TeslaMate.Log.ChargingProcess

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "充电",
       report: nil,
       editing_charge: nil,
       cost_changeset: nil,
       cost_notice: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    report = Fleet.charging(socket.assigns.current_user, params["car"], params["days"] || 90)

    {:noreply,
     assign(socket,
       report: report,
       editing_charge: nil,
       cost_changeset: nil,
       cost_notice: nil
     )}
  end

  @impl true
  def handle_event("select_vehicle", %{"vehicle" => %{"id" => id}}, socket) do
    {:noreply,
     push_patch(socket,
       to: Routes.dashboard_path(socket, :charging, car: id, days: socket.assigns.report.days)
     )}
  end

  def handle_event("select_range", %{"days" => days}, socket) do
    car_id = socket.assigns.report.car && socket.assigns.report.car.id

    {:noreply,
     push_patch(socket, to: Routes.dashboard_path(socket, :charging, car: car_id, days: days))}
  end

  def handle_event("edit_cost", %{"id" => id}, socket) do
    selected = Enum.find(socket.assigns.report[:sessions] || [], &(to_string(&1.id) == id))
    charge = selected && ChargeCosts.get(socket.assigns.current_user, selected.id)

    case charge do
      %ChargingProcess{end_date: end_date} when not is_nil(end_date) ->
        {:noreply,
         assign(socket,
           editing_charge: charge,
           cost_changeset: ChargeCosts.change(charge),
           cost_notice: nil
         )}

      %ChargingProcess{} ->
        {:noreply, cost_error(socket, "充电结束后可填写实际费用。")}

      _ ->
        {:noreply, cost_error(socket, "记录不存在或你已没有修改权限。")}
    end
  end

  def handle_event("cancel_cost", _params, socket) do
    {:noreply, assign(socket, editing_charge: nil, cost_changeset: nil, cost_notice: nil)}
  end

  def handle_event(
        "save_cost",
        %{"charge_cost" => params},
        %{assigns: %{editing_charge: %ChargingProcess{} = charge}} = socket
      )
      when is_map(params) do
    case ChargeCosts.update(socket.assigns.current_user, charge, params) do
      {:ok, updated} ->
        message =
          if is_nil(updated.cost),
            do: "费用已清空，记录标记为未填写。",
            else: "费用已保存，统计已更新。"

        {:noreply,
         socket
         |> reload_report()
         |> assign(
           editing_charge: nil,
           cost_changeset: nil,
           cost_notice: %{error: false, message: message}
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, cost_changeset: changeset)}

      {:error, :conflict} ->
        {:noreply, cost_error(socket, "费用已被更新，请重新打开编辑后确认。")}

      {:error, :in_progress} ->
        {:noreply, cost_error(socket, "充电结束后可填写实际费用。")}

      {:error, :forbidden} ->
        {:noreply, cost_error(socket, "记录不存在或你已没有修改权限。")}
    end
  end

  def handle_event("save_cost", _params, socket) do
    {:noreply, cost_error(socket, "请先选择要修改的充电记录。")}
  end

  defp reload_report(socket) do
    report = socket.assigns.report
    car_id = report.car && report.car.id
    assign(socket, report: Fleet.charging(socket.assigns.current_user, car_id, report.days))
  end

  defp cost_error(socket, message) do
    socket
    |> reload_report()
    |> assign(
      editing_charge: nil,
      cost_changeset: nil,
      cost_notice: %{error: true, message: message}
    )
  end
end
