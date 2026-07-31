defmodule TeslaMateWeb.VehicleLive.Index do
  use TeslaMateWeb, :live_view

  alias TeslaMate.{Accounts, Fleet}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket, claim_error: nil)}
  end

  @impl true
  def handle_event("redeem_claim", %{"claim" => %{"claim_code" => code}}, socket) do
    case Accounts.redeem_vehicle_claim(socket.assigns.current_user, code) do
      {:ok, _binding} ->
        {:noreply,
         socket
         |> put_flash(:success, "车辆绑定成功")
         |> load(claim_error: nil)}

      {:error, :invalid_or_expired_claim} ->
        {:noreply, assign(socket, claim_error: "认领码无效、已过期或已经使用")}
    end
  end

  def handle_event("unbind", %{"car-id" => car_id}, socket) do
    case Accounts.unbind_own_car(socket.assigns.current_user, car_id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:success, "已解除当前账号的车辆绑定")
         |> load(claim_error: nil)}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, "账号状态已变化，请重新登录")
         |> redirect(to: "/sign_in")}
    end
  end

  defp load(socket, extra) do
    cars = Accounts.list_accessible_cars(socket.assigns.current_user)

    reports =
      Map.new(cars, fn car ->
        report = Fleet.home(socket.assigns.current_user, car.id)
        {car.id, report}
      end)

    assign(socket,
      [page_title: "车辆中心", cars: cars, reports: reports] ++ extra
    )
  end
end
