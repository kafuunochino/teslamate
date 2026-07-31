defmodule TeslaMateWeb.UserAuth do
  @moduledoc false

  import Phoenix.Component
  import Phoenix.Controller
  import Plug.Conn

  alias TeslaMate.Accounts
  alias TeslaMateWeb.Router.Helpers, as: Routes

  @session_key :user_session_token

  def fetch_current_user(conn, _opts) do
    token = get_session(conn, @session_key)

    conn
    |> assign(:current_user_session_token, token)
    |> assign(:current_user, Accounts.get_user_by_session_token(token))
  end

  def redirect_if_authenticated(%Plug.Conn{assigns: %{current_user: user}} = conn, _opts)
      when not is_nil(user) do
    conn |> redirect(to: Routes.dashboard_path(conn, :home)) |> halt()
  end

  def redirect_if_authenticated(conn, _opts), do: conn

  def require_authenticated_user(%Plug.Conn{assigns: %{current_user: nil}} = conn, _opts) do
    conn
    |> put_flash(:error, "请先登录后继续")
    |> redirect(to: Routes.user_session_path(conn, :new))
    |> halt()
  end

  def require_authenticated_user(conn, _opts), do: conn

  def require_admin(%Plug.Conn{assigns: %{current_user: user}} = conn, _opts) do
    if Accounts.admin?(user) do
      conn
    else
      conn
      |> put_status(:not_found)
      |> put_view(TeslaMateWeb.ErrorView)
      |> render("404.html")
      |> halt()
    end
  end

  def log_in_user(conn, user) do
    with {:ok, token} <- Accounts.create_session(user) do
      conn
      |> configure_session(renew: true)
      |> put_session(@session_key, token)
      |> redirect(to: Routes.dashboard_path(conn, :home))
    end
  end

  def log_out_user(conn) do
    Accounts.delete_session(get_session(conn, @session_key))

    conn
    |> configure_session(drop: true)
    |> redirect(to: Routes.user_session_path(conn, :new))
  end

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_user(socket, session)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "请先登录后继续")
       |> Phoenix.LiveView.redirect(to: Routes.user_session_path(socket, :new))}
    end
  end

  def on_mount(:ensure_admin, _params, session, socket) do
    socket = mount_user(socket, session)

    if Accounts.admin?(socket.assigns.current_user) do
      {:cont, attach_admin_recheck(socket)}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "该页面仅管理员可访问")
       |> Phoenix.LiveView.redirect(to: Routes.dashboard_path(socket, :home))}
    end
  end

  defp mount_user(socket, session) do
    assign_new(socket, :current_user, fn ->
      session
      |> Map.get(Atom.to_string(@session_key))
      |> Accounts.get_user_by_session_token()
    end)
  end

  defp attach_admin_recheck(socket) do
    Phoenix.LiveView.attach_hook(
      socket,
      :platform_admin_recheck,
      :handle_event,
      fn _event, _params, socket ->
        if Accounts.authorized_admin?(socket.assigns.current_user) do
          {:cont, socket}
        else
          {:halt,
           socket
           |> Phoenix.LiveView.put_flash(:error, "管理员权限已变化，请重新登录")
           |> Phoenix.LiveView.redirect(to: Routes.user_session_path(socket, :new))}
        end
      end
    )
  end
end
