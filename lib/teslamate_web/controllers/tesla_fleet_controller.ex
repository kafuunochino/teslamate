defmodule TeslaMateWeb.TeslaFleetController do
  use TeslaMateWeb, :controller
  import Ecto.Query
  alias TeslaMate.{Repo, TeslaFleet}
  alias TeslaMate.TeslaFleet.Config
  @cookie "_teslamate_fleet_oauth"
  @page "/admin/tesla-account/fleet"

  def index(conn, _params) do
    c = case Config.get() do {:ok, c} -> c; _ -> %{} end
    connection = TeslaFleet.connection()
    cars = if connection do
      vins = Map.keys(connection.vehicles)
      Repo.all(from car in TeslaMate.Log.Car, where: car.vin in ^vins, order_by: car.id)
    else
      []
    end
    render(conn, "index.html", page_title: "Tesla 官方接入", configured: Config.configured?(),
      connected: not is_nil(connection), cars: cars,
      domain: c["domain"] || URI.parse(c["origin"] || "").host,
      interval: 10, result: nil)
  end

  def start(conn, _params) do
    token = conn.assigns.current_user_session_token
    case TeslaFleet.start_authorization(token) do
      {:ok, url, state} ->
        cookie = Jason.encode!(%{"state" => state, "token" => Base.url_encode64(token, padding: false)})
        conn
        |> put_resp_cookie(@cookie, cookie, encrypt: true, secure: conn.scheme == :https or Mix.env() == :prod,
          http_only: true, same_site: "Lax", max_age: 600, path: "/auth/tesla")
        |> put_resp_header("cache-control", "no-store")
        |> redirect(external: url)
      {:error, reason} -> failure(conn, reason)
    end
  end

  def callback(conn, params) do
    conn = fetch_cookies(conn, encrypted: [@cookie])
    cookie = conn.cookies[@cookie]
    conn = conn |> delete_resp_cookie(@cookie, path: "/auth/tesla")
      |> put_resp_header("cache-control", "no-store") |> put_resp_header("referrer-policy", "no-referrer")
    with {:ok, %{"state" => expected, "token" => encoded}} <- Jason.decode(cookie || ""),
         {:ok, token} <- Base.url_decode64(encoded, padding: false),
         {:ok, user} <- TeslaFleet.consume_state(params["state"], expected, token),
         code when is_binary(code) <- params["code"],
         {:ok, _} <- TeslaFleet.connect(code, user) do
      conn |> put_session(:user_session_token, token)
        |> put_flash(:info, "Tesla 官网授权成功，现有采集与历史数据已保留")
        |> redirect(to: @page)
    else
      {:error, reason} -> failure(conn, reason)
      _ -> failure(conn, :invalid_state)
    end
  end

  def check(conn, %{"vin" => vin}) do
    render_result(conn, TeslaFleet.check_vehicle(vin))
  end

  def configure(conn, %{"vin" => vin, "interval" => interval}) do
    result = case Integer.parse(interval) do
      {seconds, ""} when seconds in [5, 10, 30, 60, 300] -> TeslaFleet.configure_vehicle(vin, seconds)
      _ -> {:error, :invalid_interval}
    end
    render_result(conn, result)
  end

  def public_key(conn, _) do
    with {:ok, c} <- Config.get(),
         path when is_binary(path) <- c["public_key_file"],
         {:ok, pem} <- File.read(path),
         true <- String.starts_with?(pem, "-----BEGIN PUBLIC KEY-----") do
      conn |> put_resp_content_type("application/x-pem-file")
        |> put_resp_header("cache-control", "public, max-age=300") |> send_resp(200, pem)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  defp render_result(conn, {:error, reason}), do: failure(conn, reason)
  defp render_result(conn, {:ok, result}) do
    c = case Config.get() do {:ok, c} -> c; _ -> %{} end
    connection = TeslaFleet.connection()
    vins = if connection, do: Map.keys(connection.vehicles), else: []
    cars = Repo.all(from car in TeslaMate.Log.Car, where: car.vin in ^vins, order_by: car.id)
    render(conn, "index.html", page_title: "Tesla 官方接入", configured: Config.configured?(),
      connected: not is_nil(connection), cars: cars,
      domain: c["domain"] || URI.parse(c["origin"] || "").host,
      interval: 10, result: result)
  end
  defp failure(conn, reason), do: conn |> put_flash(:error, TeslaFleet.error_message(reason)) |> redirect(to: @page)
end
