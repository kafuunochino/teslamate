defmodule TeslaMateWeb.Plugs.ApiGate do
  @moduledoc """
  Requires an active platform administrator for every mutating `/api/*`
  request. Vehicle-control endpoints are never available to member accounts.
  """

  import Plug.Conn

  alias TeslaMate.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      nil -> reject(conn, 401, "unauthorized")
      user -> if Accounts.admin?(user), do: conn, else: reject(conn, 403, "forbidden")
    end
  end

  defp reject(conn, status, reason) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(status, Jason.encode!(%{error: reason}))
    |> halt()
  end
end
