defmodule TeslaMateWeb.AdminLive.Users do
  use TeslaMateWeb, :live_view

  alias TeslaMate.{Accounts, Log}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket, new_claim: nil)}
  end

  @impl true
  def handle_event("create_claim", %{"claim" => %{"car_id" => car_id, "hours" => hours}}, socket) do
    hours = parse_hours(hours)

    case Accounts.create_vehicle_claim(socket.assigns.current_user, car_id, hours: hours) do
      {:ok, claim, raw_token} ->
        car = Enum.find(socket.assigns.cars, &(&1.id == claim.car_id))
        {:noreply, load(socket, new_claim: %{code: raw_token, claim: claim, car: car})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "无法创建认领码：#{inspect(reason)}")}
    end
  end

  def handle_event("update_user", %{"id" => id, "role" => role, "status" => status}, socket) do
    with %Accounts.User{} = target <- Accounts.get_user(id) do
      case Accounts.update_user_access(socket.assigns.current_user, target, %{role: role, status: status}) do
        {:ok, _user} -> {:noreply, socket |> put_flash(:success, "用户权限已更新") |> load(new_claim: nil)}
        {:error, :last_active_admin} -> {:noreply, put_flash(socket, :error, "不能停用或降级最后一个有效管理员")}
        {:error, reason} -> {:noreply, put_flash(socket, :error, "更新失败：#{inspect(reason)}")}
      end
    else
      nil -> {:noreply, put_flash(socket, :error, "用户不存在")}
    end
  end

  def handle_event("grant_car", %{"binding" => %{"user_id" => user_id, "car_id" => car_id}}, socket) do
    with %Accounts.User{} = target <- Accounts.get_user(user_id) do
      case Accounts.grant_car(socket.assigns.current_user, target, car_id) do
        {:ok, _binding} -> {:noreply, socket |> put_flash(:success, "车辆权限已授予") |> load(new_claim: nil)}
        {:error, reason} -> {:noreply, put_flash(socket, :error, "授权失败：#{inspect(reason)}")}
      end
    else
      nil -> {:noreply, put_flash(socket, :error, "用户不存在")}
    end
  end

  def handle_event("revoke_car", %{"user-id" => user_id, "car-id" => car_id}, socket) do
    with %Accounts.User{} = target <- Accounts.get_user(user_id),
         :ok <- Accounts.revoke_car(socket.assigns.current_user, target, car_id) do
      {:noreply, socket |> put_flash(:success, "车辆权限已撤销") |> load(new_claim: nil)}
    else
      nil -> {:noreply, put_flash(socket, :error, "用户不存在")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "撤销失败：#{inspect(reason)}")}
    end
  end

  def handle_event("revoke_claim", %{"id" => id}, socket) do
    case Accounts.revoke_vehicle_claim(socket.assigns.current_user, id) do
      :ok -> {:noreply, socket |> put_flash(:success, "认领码已撤销") |> load(new_claim: nil)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "撤销失败：#{inspect(reason)}")}
    end
  end

  defp load(socket, extra) do
    if Accounts.authorized_admin?(socket.assigns.current_user) do
      users = Accounts.list_users(socket.assigns.current_user)

      assign(socket,
        [
          page_title: "用户与车辆权限",
          users: users,
          cars: Log.list_cars(),
          claims: Accounts.list_vehicle_claims(socket.assigns.current_user),
          audit_events: Accounts.list_audit_events(socket.assigns.current_user, 80)
        ] ++ extra
      )
    else
      socket
      |> put_flash(:error, "管理员权限已变化，请重新登录")
      |> redirect(to: "/sign_in")
    end
  end

  defp parse_hours(value) do
    case Integer.parse(to_string(value)) do
      {hours, ""} -> hours
      _ -> 24
    end
  end
end
