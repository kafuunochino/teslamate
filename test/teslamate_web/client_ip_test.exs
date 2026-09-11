defmodule TeslaMateWeb.ClientIPTest do
  use TeslaMateWeb.ConnCase, async: false

  alias TeslaMate.{Accounts, Repo}
  alias TeslaMate.Accounts.{Authenticator, UserSession}
  alias TeslaMate.Auth.LoginAudit
  alias TeslaMateWeb.Plugs.{ClientIP, LoginRateLimit}

  @password "correct horse battery staple 42"

  setup %{current_user: user} do
    previous = System.get_env("TESLAMATE_TRUSTED_PROXIES")
    System.put_env("TESLAMATE_TRUSTED_PROXIES", "172.18.0.1")
    LoginRateLimit.ensure_started()
    :ets.delete_all_objects(:teslamate_login_rate_limits)
    LoginAudit.reset()
    start_supervised!(TeslaMate.Vault)

    user =
      user
      |> Ecto.Changeset.change(password_hash: Accounts.Password.hash(@password))
      |> Repo.update!()

    on_exit(fn ->
      if previous,
        do: System.put_env("TESLAMATE_TRUSTED_PROXIES", previous),
        else: System.delete_env("TESLAMATE_TRUSTED_PROXIES")

      :ets.delete_all_objects(:teslamate_login_rate_limits)
    end)

    %{current_user: user}
  end

  test "login, audit, cookie session and device page agree on the real client IP", %{
    current_user: user
  } do
    conn = post(proxied_conn(), "/sign_in", %{user: %{email: user.email, password: @password}})
    assert redirected_to(conn) == "/"
    assert get_session(conn, :client_ip) == "198.51.100.10"
    assert login_session(conn).ip_address == "198.51.100.10"
    assert [%{ip: "198.51.100.10", outcome: :success}] = LoginAudit.recent()

    html = conn |> recycle() |> get("/account") |> html_response(200)
    assert html =~ "IP：198.51.100.10"
    refute html =~ "::ffff:172.18.0.1"
  end

  test "second-factor completion records the verified request IP", %{current_user: user} do
    secret = NimbleTOTP.secret()
    Repo.insert!(%Authenticator{user_id: user.id, secret: secret, enabled_at: DateTime.utc_now()})
    conn = post(proxied_conn(), "/sign_in", %{user: %{email: user.email, password: @password}})
    assert redirected_to(conn) == "/sign_in/verify"
    refute get_session(conn, :user_session_token)

    conn =
      conn
      |> recycle()
      |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 0xFFFF, 0xAC12, 1})
      |> put_req_header("x-forwarded-for", "203.0.113.99, 198.51.100.20")
      |> post("/sign_in/verify", %{verification: %{code: NimbleTOTP.verification_code(secret)}})

    assert redirected_to(conn) == "/"
    assert login_session(conn).ip_address == "198.51.100.20"
    assert [%{ip: "198.51.100.20", outcome: :success}] = LoginAudit.recent()
  end

  test "failed logins behind the same Docker proxy use separate client rate-limit buckets", %{
    current_user: user
  } do
    for address <- ["198.51.100.10", "198.51.100.20"] do
      conn =
        proxied_conn()
        |> put_req_header("x-forwarded-for", "203.0.113.99, #{address}")
        |> post("/sign_in", %{user: %{email: user.email, password: "incorrect"}})

      refute get_session(conn, :user_session_token)
      assert LoginRateLimit.hit_count(:ip, address) == 1
    end

    assert LoginRateLimit.hit_count(:ip, "172.18.0.1") == 0
    assert LoginRateLimit.hit_count(:ip, "::ffff:172.18.0.1") == 0
    assert LoginRateLimit.hit_count(:ip, "203.0.113.99") == 0
    assert Enum.sort(Enum.map(LoginAudit.recent(), & &1.ip)) == ["198.51.100.10", "198.51.100.20"]
  end

  test "direct callers of auth metadata and the rate-limit plug use the same resolver" do
    conn = proxied_conn()
    assert TeslaMateWeb.UserAuth.session_metadata(conn).ip_address == "198.51.100.10"
    assert LoginRateLimit.call(conn, []).private.login_rate_limit == {ClientIP.resolve(conn), nil}
  end

  defp proxied_conn do
    build_conn()
    |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 0xFFFF, 0xAC12, 1})
    |> put_req_header("x-forwarded-for", "203.0.113.99, 198.51.100.10")
  end

  defp login_session(conn) do
    token = get_session(conn, :user_session_token)
    Repo.get_by!(UserSession, token_hash: :crypto.hash(:sha256, token))
  end
end
