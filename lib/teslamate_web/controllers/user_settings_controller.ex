defmodule TeslaMateWeb.UserSettingsController do
  use TeslaMateWeb, :controller
  alias TeslaMate.Accounts
  alias TeslaMate.Accounts.Security
  alias TeslaMateWeb.UserAuth

  def edit(conn, _params), do: render_settings(conn)

  def request_deletion(conn, %{"confirmation" => params}) when is_map(params) do
    case Accounts.Lifecycle.request_deletion(conn.assigns.current_user, session_token(conn), params) do
      {:ok, user} ->
        deadline = TeslaMateWeb.PlatformComponents.date_time(user.deletion_scheduled_at)
        conn
        |> configure_session(renew: true)
        |> clear_session()
        |> put_flash(:info, "注销申请已提交，将于 #{deadline} 后自动删除账号。七天内完整登录可取消注销。")
        |> redirect(to: "/sign_in")

      {:error, reason} ->
        conn
        |> put_flash(:error, Accounts.Lifecycle.error_message(reason))
        |> redirect(to: "/account#account-deletion")
    end
  end

  def request_deletion(conn, _), do: bad_request(conn)

  def update_profile(conn, %{"user" => params}) when is_map(params) do
    case Accounts.update_profile(conn.assigns.current_user, params) do
      {:ok, _} ->
        conn |> put_flash(:success, "个人资料已更新") |> redirect(to: "/account")

      {:error, %Ecto.Changeset{} = changeset} ->
        render_settings(put_status(conn, :unprocessable_entity), profile_changeset: changeset)

      _ ->
        failed(conn, :forbidden)
    end
  end

  def update_profile(conn, _), do: bad_request(conn)

  def update_password(conn, %{"user" => params}) when is_map(params) do
    user = conn.assigns.current_user
    password = params["current_password"] || ""

    with :ok <-
           Security.authorize_password_change(user, session_token(conn), password, params["code"]),
         {:ok, _} <- Accounts.update_password(user, password, params) do
      conn |> put_flash(:success, "密码已更新，所有设备已登出，请重新登录") |> UserAuth.log_out_user()
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        render_settings(put_status(conn, :unprocessable_entity), password_changeset: changeset)

      {:error, reason} ->
        failed(conn, reason)
    end
  end

  def update_password(conn, _), do: bad_request(conn)

  def begin_two_factor(conn, %{"security" => params}) when is_map(params) do
    case Security.begin_enrollment(
           conn.assigns.current_user,
           session_token(conn),
           params["password"]
         ) do
      {:ok, _} ->
        conn |> put_flash(:success, "请用验证器扫描二维码，并输入动态码确认启用") |> redirect(to: "/account#security")

      {:error, reason} ->
        failed(conn, reason)
    end
  end

  def begin_two_factor(conn, _), do: bad_request(conn)

  def enable_two_factor(conn, %{"security" => params}) when is_map(params) do
    result =
      Security.enable(
        conn.assigns.current_user,
        session_token(conn),
        params["code"],
        UserAuth.session_metadata(conn)
      )

    security_result(conn, result, "两步验证已启用，其他登录设备已登出")
  end

  def enable_two_factor(conn, _), do: bad_request(conn)

  def disable_two_factor(conn, %{"security" => params}) when is_map(params) do
    result =
      Security.disable(
        conn.assigns.current_user,
        session_token(conn),
        params["password"],
        params["code"],
        UserAuth.session_metadata(conn)
      )

    security_result(conn, result, "两步验证已关闭，旧恢复码已失效，其他登录设备已登出")
  end

  def disable_two_factor(conn, _), do: bad_request(conn)

  def recovery_codes(conn, %{"security" => params}) when is_map(params) do
    result =
      Security.regenerate_recovery_codes(
        conn.assigns.current_user,
        session_token(conn),
        params["password"],
        params["code"],
        UserAuth.session_metadata(conn)
      )

    security_result(conn, result, "恢复码已重新生成，旧恢复码已失效，其他登录设备已登出")
  end

  def recovery_codes(conn, _), do: bad_request(conn)

  def revoke_device(conn, %{"id" => id}) do
    case Accounts.revoke_session(conn.assigns.current_user, id) do
      :ok ->
        if Accounts.get_user_by_session_token(session_token(conn)) do
          conn |> put_flash(:success, "该设备已强制登出") |> redirect(to: "/account#devices")
        else
          UserAuth.log_out_user(conn)
        end

      _ ->
        conn |> put_status(:not_found) |> put_view(TeslaMateWeb.ErrorView) |> render("404.html")
    end
  end

  def revoke_other_devices(conn, _) do
    case Accounts.revoke_other_sessions(conn.assigns.current_user, session_token(conn)) do
      :ok -> conn |> put_flash(:success, "其他设备已全部登出") |> redirect(to: "/account#devices")
      _ -> failed(conn, :forbidden)
    end
  end

  defp security_result(conn, {:ok, codes, token}, message) do
    conn =
      conn
      |> UserAuth.put_authenticated_session(token)
      |> assign(:current_user, Accounts.get_user_by_session_token(token))
      |> assign(:current_user_session_token, token)
      |> put_flash(:success, message)

    if codes == [],
      do: redirect(conn, to: "/account#security"),
      else: render_settings(conn, recovery_codes: codes)
  end

  defp security_result(conn, {:error, reason}, _), do: failed(conn, reason)

  defp render_settings(conn, overrides \\ []) do
    user = conn.assigns.current_user

    defaults = [
      page_title: "账号设置",
      profile_changeset: Accounts.User.profile_changeset(user, %{}),
      password_changeset: Accounts.User.password_changeset(user, %{}),
      security: Security.status(user, session_token(conn)),
      sessions: Accounts.list_sessions(user, session_token(conn)),
      recovery_codes: [],
      system_admin: Accounts.system_admin?(user)
    ]

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> render("edit.html", Keyword.merge(defaults, overrides))
  end

  defp session_token(conn), do: conn.assigns.current_user_session_token

  defp bad_request(conn), do: conn |> send_resp(:bad_request, "Invalid request")

  defp failed(conn, reason) do
    message =
      case reason do
        :rate_limited -> "验证尝试过多，请 10 分钟后重试"
        :setup_expired -> "设置已过期，请重新验证密码后添加验证器"
        :already_enabled -> "两步验证已经启用"
        :not_enabled -> "请先启用两步验证"
        :forbidden -> "登录状态已变化，请重新登录"
        _ -> "密码或验证码无效，动态码不能重复使用"
      end

    conn |> put_flash(:error, message) |> redirect(to: "/account#security")
  end
end
