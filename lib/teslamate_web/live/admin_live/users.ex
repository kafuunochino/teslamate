defmodule TeslaMateWeb.AdminLive.Users do
  use TeslaMateWeb, :live_view

  alias TeslaMate.{Accounts, Log}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket, new_claim: nil, deletion_target: nil)}
  end

  @impl true
  def handle_event("registration_policy", %{"registration" => params}, socket) do
    allowed = params["enabled"] == "true"

    case Accounts.set_registration(socket.assigns.current_user, allowed) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(:allow_registration, allowed) |> put_flash(:success, "注册设置已保存")}

      _ ->
        {:noreply, socket |> put_flash(:error, "没有修改注册设置的权限") |> redirect(to: "/sign_in")}
    end
  end

  def handle_event("create_claim", %{"claim" => %{"car_id" => car_id, "hours" => hours}}, socket) do
    hours = parse_hours(hours)

    case Accounts.create_vehicle_claim(socket.assigns.current_user, car_id, hours: hours) do
      {:ok, claim, raw_token} ->
        car = Enum.find(socket.assigns.cars, &(&1.id == claim.car_id))
        {:noreply, load(socket, new_claim: %{code: raw_token, claim: claim, car: car})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "无法创建认领码：#{access_error(reason)}")}
    end
  end

  def handle_event("update_user", %{"id" => id} = params, socket) do
    with %Accounts.User{} = target <- Accounts.get_user(id) do
      case Accounts.update_user_access(socket.assigns.current_user, target, Map.take(params, ["role", "status"])) do
        {:ok, _user} ->
          {:noreply, socket |> put_flash(:success, "账号状态已更新") |> load(new_claim: nil)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, Accounts.Lifecycle.error_message(reason))}
      end
    else
      nil -> {:noreply, put_flash(socket, :error, "用户不存在")}
    end
  end

  def handle_event("prepare_delete", %{"id" => id}, socket) do
    case {Accounts.authorized_admin?(socket.assigns.current_user), Accounts.get_user(id)} do
      {true, %Accounts.User{is_system_admin: false} = user} ->
        {:noreply, assign(socket, :deletion_target, %{id: user.id, email: user.email})}

      {true, %Accounts.User{is_system_admin: true}} ->
        {:noreply, put_flash(socket, :error, Accounts.Lifecycle.error_message(:system_admin_protected))}

      _ ->
        {:noreply, put_flash(socket, :error, "没有删除该账号的权限")}
    end
  end

  def handle_event("cancel_delete", _, socket),
    do: {:noreply, assign(socket, :deletion_target, nil)}

  def handle_event("confirm_delete", %{"confirmation" => params}, socket) when is_map(params) do
    case socket.assigns.deletion_target do
      %{id: id} ->
        case Accounts.Lifecycle.delete_account(
          socket.assigns.current_user, socket.assigns.current_user_session_token, id, params
        ) do
          {:ok, _} ->
            {:noreply,
             socket |> put_flash(:success, "账号已删除，车辆历史已保留，仅管理员可见")
             |> load(new_claim: nil, deletion_target: nil)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, Accounts.Lifecycle.error_message(reason))}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "请先选择需要删除的账号，再完成二次确认")}
    end
  end

  def handle_event(
        "grant_car",
        %{"binding" => %{"user_id" => user_id, "car_id" => car_id}},
        socket
      ) do
    with %Accounts.User{} = target <- Accounts.get_user(user_id) do
      case Accounts.grant_car(socket.assigns.current_user, target, car_id) do
        {:ok, _binding} ->
          {:noreply, socket |> put_flash(:success, "车辆权限已授予") |> load(new_claim: nil)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "授权失败：#{access_error(reason)}")}
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

  def handle_event(_, _, socket), do: {:noreply, put_flash(socket, :error, "无效操作，请刷新后重试")}

  defp load(socket, extra) do
    if Accounts.authorized_admin?(socket.assigns.current_user) do
      users = Accounts.list_users(socket.assigns.current_user)

      assign(
        socket,
        [
          page_title: "用户与车辆权限",
          deletion_requires_code: Accounts.Security.enabled?(socket.assigns.current_user),
          allow_registration: Accounts.sign_up_allowed?(),
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

  defp access_error(:vehicle_already_bound), do: "车辆已有所属账号，请先核对并撤销原归属"
  defp access_error(_), do: "账号或车辆状态已变化，请刷新后重试"

  defp parse_hours(value) do
    case Integer.parse(to_string(value)) do
      {hours, ""} -> hours
      _ -> 24
    end
  end
end
