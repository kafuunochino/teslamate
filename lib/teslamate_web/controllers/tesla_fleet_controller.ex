defmodule TeslaMateWeb.TeslaFleetController do
  use TeslaMateWeb, :controller
  alias TeslaMate.{Accounts, TeslaFleet}
  alias TeslaMate.TeslaFleet.Config
  @cookie "_teslamate_fleet_oauth"
  @secure_cookie Mix.env() == :prod
  @page "/tesla-account"

  def index(conn, _params), do: render_page(conn, nil)

  def start(conn, _params) do
    token = conn.assigns.current_user_session_token

    case TeslaFleet.start_authorization(token) do
      {:ok, url, state} ->
        cookie =
          Jason.encode!(%{"state" => state, "token" => Base.url_encode64(token, padding: false)})

        conn
        |> put_resp_cookie(@cookie, cookie,
          encrypt: true,
          secure: conn.scheme == :https or @secure_cookie,
          http_only: true,
          same_site: "Lax",
          max_age: 600,
          path: "/auth/tesla"
        )
        |> put_resp_header("cache-control", "no-store")
        |> redirect(external: url)

      {:error, reason} ->
        failure(conn, reason)
    end
  end

  def callback(conn, params) do
    conn = fetch_cookies(conn, encrypted: [@cookie])
    cookie = conn.cookies[@cookie]

    conn =
      conn
      |> delete_resp_cookie(@cookie, path: "/auth/tesla")
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")

    with {:ok, %{"state" => expected, "token" => encoded}} <- Jason.decode(cookie || ""),
         {:ok, token} <- Base.url_decode64(encoded, padding: false),
         {:ok, user} <- TeslaFleet.consume_state(params["state"], expected, token),
         code when is_binary(code) <- params["code"],
         {:ok, _} <- TeslaFleet.connect(code, user, token) do
      if Accounts.get_user_by_session_token(token) do
        conn
        |> put_session(:user_session_token, token)
        |> put_session(:live_socket_id, Accounts.live_socket_id(token))
        |> assign(:current_user, user)
        |> assign(:current_user_session_token, token)
        |> assign(:tesla_fleet_completed, true)
        |> put_flash(:info, "Tesla 官网授权成功，车辆已关联到当前账号")
        |> render("completed.html", page_title: "Tesla 授权成功")
      else
        conn |> put_flash(:info, "车辆授权已更新，请重新登录") |> redirect(to: "/sign_in")
      end
    else
      {:error, reason} -> failure(conn, reason)
      _ -> failure(conn, :invalid_state)
    end
  end

  def check(conn, %{"vin" => vin}) do
    render_result(conn, TeslaFleet.check_vehicle(conn.assigns.current_user, vin))
  end

  def check(conn, _), do: failure(conn, :unknown_vehicle)

  def configure(conn, %{"vin" => vin, "interval" => interval}) when is_binary(interval) do
    result =
      case Integer.parse(interval) do
        {seconds, ""} when seconds in [5, 10, 30, 60, 300] ->
          TeslaFleet.configure_vehicle(conn.assigns.current_user, vin, seconds)

        _ ->
          {:error, :invalid_interval}
      end

    render_result(conn, result)
  end

  def configure(conn, _), do: failure(conn, :unknown_vehicle)

  def disconnect(conn, _) do
    case TeslaFleet.disconnect(conn.assigns.current_user) do
      {:ok, :ok} ->
        conn
        |> put_flash(:info, "本账号的 Tesla 授权已解除，历史车辆数据已保留，请重新登录")
        |> TeslaMateWeb.UserAuth.log_out_user()

      {:error, reason} ->
        failure(conn, reason)
    end
  end

  def public_key(conn, _) do
    with {:ok, c} <- Config.get(),
         path when is_binary(path) <- c["public_key_file"],
         {:ok, pem} <- File.read(path),
         true <- String.starts_with?(pem, "-----BEGIN PUBLIC KEY-----") do
      conn
      |> put_resp_content_type("application/x-pem-file")
      |> put_resp_header("cache-control", "public, max-age=300")
      |> send_resp(200, pem)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  defp render_page(conn, result) do
    c =
      case Config.get() do
        {:ok, c} -> c
        _ -> %{}
      end

    user = conn.assigns.current_user

    render(conn, "index.html",
      page_title: "Tesla 连接",
      configured: Config.configured?(),
      connected: not is_nil(TeslaFleet.connection(user)),
      cars: TeslaFleet.connected_cars(user),
      domain: c["domain"] || URI.parse(c["origin"] || "").host,
      interval: 10,
      result: result
    )
  end

  defp render_result(conn, {:error, reason}), do: failure(conn, reason)
  defp render_result(conn, {:ok, result}), do: render_page(conn, result)

  defp failure(conn, reason),
    do: conn |> put_flash(:error, TeslaFleet.error_message(reason)) |> redirect(to: @page)
end
