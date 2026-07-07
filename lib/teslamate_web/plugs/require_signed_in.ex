defmodule TeslaMateWeb.Plugs.RequireSignedIn do
  @moduledoc """
  Forces every request through this plug to have a signed-in Tesla session.

  Used as a plug in `TeslaMateWeb.Router`. To preserve backward compatibility,
  the redirect is only enforced when the operator opts into the new behaviour
  by setting `TESLAMATE_STRICT_AUTH=true`. With the default (unset / `false`)
  the plug simply annotates `:signed_in?` on the conn and leaves the request
  untouched so existing deployments keep working unchanged.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias TeslaMate.Api

  @strict String.to_existing_atom(
            System.get_env("TESLAMATE_STRICT_AUTH", "false") |> String.downcase()
          )

  def init(opts), do: opts

  def call(conn, _opts) do
    signed_in = Api.signed_in?()
    conn = assign(conn, :signed_in?, signed_in)

    if @strict == true and not signed_in do
      conn
      |> redirect(to: sign_in_path(conn))
      |> halt()
    else
      conn
    end
  end

  defp sign_in_path(conn) do
    Phoenix.Router.Routes.live_path(conn, TeslaMateWeb.SignInLive.Index)
  end
end