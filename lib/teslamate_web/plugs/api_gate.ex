defmodule TeslaMateWeb.Plugs.ApiGate do
  @moduledoc """
  Optional runtime-configurable gate for `/api/*` routes.

  TeslaMate historically left `PUT /api/car/:id/logging/{resume,suspend}` open
  because the in-app LiveView calls them with the same session cookie that
  signs the user in. Operators who want to harden the deployment can now set
  `TESLAMATE_PROTECT_API=true` (read on every request, no recompile needed) and
  the gate will reject requests from users that have not signed in.
  """

  import Plug.Conn

  alias TeslaMate.Api

  def init(opts), do: opts

  def call(conn, _opts) do
    if TeslaMateWeb.Config.protect_api?() and not Api.signed_in?() do
      body = ~s({"error":"unauthorized"})
      location = "/sign_in"

      conn
      |> put_resp_header("location", location)
      |> put_resp_header("content-type", "application/json")
      |> send_resp(401, body)
      |> halt()
    else
      conn
    end
  end
end