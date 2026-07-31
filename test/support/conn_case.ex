defmodule TeslaMateWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  it cannot be async. For this reason, every test runs
  inside a transaction which is reset at the beginning
  of the test unless the test case is marked as async.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import TeslaMateWeb.ConnCase

      alias TeslaMateWeb.Router.Helpers, as: Routes
      import Phoenix.LiveViewTest

      # The default endpoint for testing
      @endpoint TeslaMateWeb.Endpoint

      use TeslaMateWeb, :verified_routes
    end
  end

  setup tags do
    try do
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(TeslaMate.Repo, shared: not tags[:async])
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    rescue
      e in [MatchError] ->
        case e.term do
          {:error, {{:badmatch, :already_shared}, _}} -> :ok
          _ -> reraise e, __STACKTRACE__
        end
    end

    # Start the Endpoint manually since tests run with '--no-start'
    {:ok, _pid} = start_supervised(TeslaMateWeb.Endpoint)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.assign(:signed_in?, !!tags[:signed_in])

    {conn, current_user} = maybe_log_in_platform_user(conn, tags)

    {:ok, conn: conn, current_user: current_user}
  end

  defp maybe_log_in_platform_user(conn, %{auth: false}), do: {conn, nil}

  defp maybe_log_in_platform_user(conn, tags) do
    suffix = System.unique_integer([:positive, :monotonic])
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    user =
      TeslaMate.Repo.insert!(%TeslaMate.Accounts.User{
        email: "test-admin-#{suffix}@example.com",
        name: "Test Admin",
        password_hash: "test-only-not-a-valid-password-hash",
        password_changed_at: now,
        role: tags[:platform_role] || :admin,
        status: :active
      })

    {:ok, token} = TeslaMate.Accounts.create_session(user)

    conn =
      conn
      |> Plug.Test.init_test_session(%{user_session_token: token})
      |> Plug.Conn.assign(:current_user, user)

    {conn, user}
  end
end
