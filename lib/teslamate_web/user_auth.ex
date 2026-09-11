defmodule TeslaMateWeb.UserAuth do
  @moduledoc false
  import Phoenix.Component
  import Phoenix.Controller
  import Plug.Conn, except: [assign: 3]
  alias TeslaMate.Accounts
  alias TeslaMateWeb.Router.Helpers, as: Routes
  @session_key :user_session_token

  def fetch_current_user(conn, _opts) do
    token = get_session(conn, @session_key)
    user = Accounts.get_user_by_session_token(token)

    conn =
      conn
      |> Plug.Conn.assign(:current_user_session_token, token)
      |> Plug.Conn.assign(:current_user, user)
      |> put_resp_header("cache-control", "no-store")

    if user do
      Accounts.touch_session(token)
      put_session(conn, :live_socket_id, Accounts.live_socket_id(token))
    else
      conn
    end
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
    if Accounts.authorized_admin?(user) do
      conn
    else
      conn
      |> put_status(:not_found)
      |> put_view(TeslaMateWeb.ErrorView)
      |> render("404.html")
      |> halt()
    end
  end

  def session_metadata(conn) do
    ip = conn.private[:client_ip] || TeslaMateWeb.Plugs.ClientIP.resolve(conn)
    %{user_agent: get_req_header(conn, "user-agent") |> List.first(), ip_address: ip}
  end

  def log_in_user(conn, user) do
    if Accounts.Security.enabled?(user) do
      case Accounts.Security.create_challenge(user) do
        {:ok, challenge} ->
          conn
          |> configure_session(renew: true)
          |> clear_session()
          |> put_session(:login_challenge, challenge)
          |> redirect(to: "/sign_in/verify")

        _ ->
          conn |> redirect(to: "/sign_in")
      end
    else
      case Accounts.create_login_session(user, session_metadata(conn)) do
        {:ok, token} -> finish_login(conn, user, token)
        _ -> conn |> redirect(to: "/sign_in")
      end
    end
  end

  def finish_login(conn, user, token) do
    conn = put_authenticated_session(conn, token)

    conn =
      if user.deletion_scheduled_at,
        do: put_flash(conn, :success, "已取消账号注销，账号恢复正常使用"),
        else: conn

    redirect(conn, to: "/")
  end

  def put_authenticated_session(conn, token) do
    Plug.CSRFProtection.delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(@session_key, token)
    |> put_session(:live_socket_id, Accounts.live_socket_id(token))
  end

  def log_out_user(conn) do
    Accounts.delete_session(get_session(conn, @session_key))
    conn |> configure_session(drop: true) |> redirect(to: Routes.user_session_path(conn, :new))
  end

  def on_mount(:mount_current_user, _params, session, socket),
    do: {:cont, mount_user(socket, session)}

  def on_mount(requirement, _params, session, socket)
      when requirement in [:ensure_authenticated, :ensure_admin] do
    socket = mount_user(socket, session)

    if permitted?(socket.assigns.current_user, requirement) do
      if Phoenix.LiveView.connected?(socket),
        do: Process.send_after(self(), :check_account_session, 60_000)

      {:cont, attach_rechecks(socket, requirement)}
    else
      {:halt, reject_socket(socket)}
    end
  end

  defp mount_user(socket, session) do
    token = Map.get(session, Atom.to_string(@session_key))

    socket
    |> assign(:current_user, Accounts.get_user_by_session_token(token))
    |> assign(:current_user_session_token, token)
  end

  defp attach_rechecks(socket, requirement) do
    socket
    |> Phoenix.LiveView.attach_hook(:session_events, :handle_event, fn _, _, socket ->
      recheck(socket, requirement)
    end)
    |> attach_navigation_recheck(requirement)
    |> Phoenix.LiveView.attach_hook(:session_messages, :handle_info, fn message, socket ->
      case recheck(socket, requirement) do
        {:cont, socket} when message == :check_account_session ->
          Process.send_after(self(), :check_account_session, 60_000)
          {:halt, socket}

        result ->
          result
      end
    end)
  end

  defp attach_navigation_recheck(socket, requirement) do
    if socket.view in [TeslaMateWeb.CarLive.Index, TeslaMateWeb.CarLive.Summary] do
      socket
    else
      Phoenix.LiveView.attach_hook(socket, :session_navigation, :handle_params, fn _, _, socket ->
        recheck(socket, requirement)
      end)
    end
  end

  defp recheck(socket, requirement) do
    token = socket.assigns.current_user_session_token
    user = Accounts.get_user_by_session_token(token)

    if permitted?(user, requirement) do
      Accounts.touch_session(token)
      {:cont, assign(socket, :current_user, user)}
    else
      {:halt, reject_socket(socket)}
    end
  end

  defp permitted?(nil, _), do: false
  defp permitted?(user, :ensure_admin), do: Accounts.authorized_admin?(user)
  defp permitted?(_user, :ensure_authenticated), do: true

  defp reject_socket(socket) do
    socket
    |> Phoenix.LiveView.put_flash(:error, "登录或权限已失效，请重新登录")
    |> Phoenix.LiveView.redirect(to: "/sign_in")
  end
end
