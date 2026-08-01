defmodule TeslaMateWeb.UserSettingsController do
  use TeslaMateWeb, :controller

  alias TeslaMate.Accounts
  alias TeslaMateWeb.UserAuth

  def edit(conn, _params) do
    user = conn.assigns.current_user

    render(conn, "edit.html",
      page_title: "账号设置",
      profile_changeset: TeslaMate.Accounts.User.profile_changeset(user, %{}),
      password_changeset: TeslaMate.Accounts.User.password_changeset(user, %{})
    )
  end

  def update_profile(conn, %{"user" => params}) do
    case Accounts.update_profile(conn.assigns.current_user, params) do
      {:ok, _user} ->
        conn
        |> put_flash(:success, "个人资料已更新")
        |> redirect(to: Routes.user_settings_path(conn, :edit))

      {:error, changeset} ->
        render_errors(conn, profile_changeset: changeset)
    end
  end

  def update_password(conn, %{"user" => params}) do
    current_password = Map.get(params, "current_password", "")

    case Accounts.update_password(conn.assigns.current_user, current_password, params) do
      {:ok, _user} ->
        conn |> put_flash(:success, "密码已更新，请重新登录") |> UserAuth.log_out_user()

      {:error, :invalid_password} ->
        conn
        |> put_flash(:error, "当前密码不正确")
        |> redirect(to: Routes.user_settings_path(conn, :edit))

      {:error, %Ecto.Changeset{} = changeset} ->
        render_errors(conn, password_changeset: changeset)
    end
  end

  defp render_errors(conn, changes) do
    user = conn.assigns.current_user

    defaults = [
      page_title: "账号设置",
      profile_changeset: TeslaMate.Accounts.User.profile_changeset(user, %{}),
      password_changeset: TeslaMate.Accounts.User.password_changeset(user, %{})
    ]

    conn
    |> put_status(:unprocessable_entity)
    |> render("edit.html", Keyword.merge(defaults, changes))
  end
end
