defmodule TeslaMateWeb.MapController do
  use TeslaMateWeb, :controller

  alias TeslaMate.Maps
  alias TeslaMate.Maps.{AmapProxy, Settings}

  plug :require_map_user

  def config(conn, _params) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> json(Maps.browser_config())
  end

  def proxy(conn, %{"path" => path}) do
    proxy_request(conn, path)
  end

  defp proxy_request(conn, path) do
    case Maps.get_settings!() do
      %Settings{provider: :amap} = settings ->
        case AmapProxy.request(settings, path, conn.query_string) do
          {:ok, content_type, body} ->
            conn
            |> put_resp_header("content-type", content_type)
            |> put_resp_header("x-content-type-options", "nosniff")
            |> put_resp_header("cache-control", "private, no-store")
            |> send_resp(200, body)

          {:error, :invalid_request} ->
            conn |> put_status(:bad_request) |> json(%{error: "invalid_map_request"})

          {:error, _} ->
            conn |> put_status(:bad_gateway) |> json(%{error: "map_provider_unavailable"})
        end

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "map_provider_disabled"})
    end
  end

  defp require_map_user(conn, _opts) do
    case conn.assigns[:current_user] do
      %TeslaMate.Accounts.User{status: :active} ->
        conn

      _ ->
        conn |> put_status(:unauthorized) |> json(%{error: "authentication_required"}) |> halt()
    end
  end
end
