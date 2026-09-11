defmodule TeslaMateWeb.AccountSecurityTest do
  use TeslaMateWeb.ConnCase, async: false
  alias TeslaMate.{Accounts, Repo}
  alias TeslaMate.Accounts.{Authenticator, Security, UserSession}
  @password "correct horse battery staple 42"

  setup %{current_user: user} do
    start_supervised!(TeslaMate.Vault)

    user =
      user
      |> Ecto.Changeset.change(password_hash: Accounts.Password.hash(@password))
      |> Repo.update!()

    %{current_user: user}
  end

  defp member do
    {:ok, member} =
      Accounts.register_user(%{
        email: "member-#{System.unique_integer([:positive])}@example.com",
        name: "Other User",
        password: @password,
        password_confirmation: @password
      })

    member
  end

  test "request logs redact verification factors and OAuth credentials" do
    values = %{
      "verification" => %{"code" => "sensitive-factor"},
      "security" => %{"password" => "sensitive-password", "code" => "recovery-factor"},
      "access_token" => "sensitive-access",
      "refresh_token" => "sensitive-refresh",
      "client_secret" => "sensitive-secret",
      "device_id" => "42"
    }

    filtered = Phoenix.Logger.filter_values(values)
    assert filtered["verification"]["code"] == "[FILTERED]"
    assert filtered["security"] == %{"password" => "[FILTERED]", "code" => "[FILTERED]"}
    assert filtered["access_token"] == "[FILTERED]"
    assert filtered["refresh_token"] == "[FILTERED]"
    assert filtered["client_secret"] == "[FILTERED]"
    assert filtered["device_id"] == "42"
  end

  test "admin registration switch persists and gates both GET and POST", %{conn: conn} do
    assert get(build_conn(), "/register").status == 404
    {:ok, view, _} = live(conn, "/admin/users")

    view
    |> form("form[phx-submit=registration_policy]", registration: %{enabled: "true"})
    |> render_submit()

    assert Accounts.sign_up_allowed?()
    assert get(build_conn(), "/register").status == 200
    assert get(build_conn(), "/sign_in").resp_body =~ "/register"
    view |> render_submit("registration_policy", %{"registration" => %{"enabled" => "false"}})
    refute Accounts.sign_up_allowed?()
    assert post(build_conn(), "/register", %{user: %{email: "blocked@example.com"}}).status == 404
    refute get(build_conn(), "/sign_in").resp_body =~ ~s(href="/register")
  end

  @tag platform_role: :member
  test "member menu exposes own Tesla and fences but system management stays inaccessible", %{
    conn: conn
  } do
    html = conn |> get("/account") |> html_response(200)
    assert html =~ ~s(href="/tesla-account")
    assert html =~ ~s(href="/geo-fences")
    refute html =~ "系统管理"

    for route <- [
          "/admin/users",
          "/admin/settings",
          "/settings",
          "/admin/tesla-account",
          "/admin/import",
          "/admin/collector"
        ] do
      assert get(conn, route).status == 404
    end

    assert get(conn, "/tesla-account").status == 200
    assert {:ok, _, _} = live(conn, "/geo-fences")
  end

  test "password-only login with 2FA enabled cannot reach account data", %{current_user: user} do
    secret = NimbleTOTP.secret()
    Repo.insert!(%Authenticator{user_id: user.id, secret: secret, enabled_at: DateTime.utc_now()})
    conn = post(build_conn(), "/sign_in", %{user: %{email: user.email, password: @password}})
    assert redirected_to(conn) == "/sign_in/verify"
    refute get_session(conn, :user_session_token)
    assert get_session(conn, :login_challenge)
    assert redirected_to(conn |> recycle() |> get("/account")) == "/sign_in"

    result =
      conn
      |> recycle()
      |> post("/sign_in/verify", %{verification: %{code: NimbleTOTP.verification_code(secret)}})

    assert redirected_to(result) == "/"
    assert get_session(result, :user_session_token)
    refute get_session(result, :login_challenge)
    assert get_session(result, :live_socket_id)
  end

  test "device identifiers cannot revoke another account and revoked token fails every route", %{
    conn: conn,
    current_user: user
  } do
    other = member()
    {:ok, token} = Accounts.create_session(other)
    row = Repo.get_by!(UserSession, token_hash: :crypto.hash(:sha256, token))
    assert delete(conn, "/account/devices/#{row.id}").status == 404
    assert Accounts.get_user_by_session_token(token)
    [{:ok, own}] = [Accounts.create_session(user)]
    own_row = Repo.get_by!(UserSession, token_hash: :crypto.hash(:sha256, own))
    assert redirected_to(delete(conn, "/account/devices/#{own_row.id}")) == "/account#devices"
    stolen = build_conn() |> Plug.Test.init_test_session(%{user_session_token: own})
    assert redirected_to(get(stolen, "/account")) == "/sign_in"
    assert get(stolen, "/maps/config").status == 401

    assert post(stolen, "/tesla-account/configure", %{vin: "LRW3E7EK9MC123456", interval: "10"}).status ==
             302
  end

  test "revoked LiveViews cannot keep processing page events or updates", %{
    conn: conn,
    current_user: user
  } do
    {:ok, view, _} = live(conn, "/geo-fences")
    [device] = Accounts.list_sessions(user, get_session(conn, :user_session_token))
    assert :ok = Accounts.revoke_session(user, device.id)
    # Older sessions without live_socket_id are also guarded at each callback.
    send(view.pid, :check_account_session)
    assert_redirect(view, "/sign_in")
  end

  test "account security page never renders persisted secrets or recovery hashes", %{
    conn: conn,
    current_user: user
  } do
    Repo.insert!(%Authenticator{
      user_id: user.id,
      secret: "never-render-this-secret",
      enabled_at: DateTime.utc_now(),
      recovery_hashes: [:crypto.hash(:sha256, "never-render-code")]
    })

    response = get(conn, "/account")
    html = html_response(response, 200)
    assert html =~ "两步验证（2FA）"
    assert html =~ "在线设备与登录会话"
    refute html =~ "never-render-this-secret"
    refute html =~ "never-render-code"
    assert get_resp_header(response, "cache-control") == ["no-store"]
  end

  test "enrollment endpoints retain password confirmation and show recovery codes only once", %{
    conn: conn
  } do
    begin = post(conn, "/account/2fa/setup", %{security: %{password: @password}})
    assert redirected_to(begin) == "/account#security"
    user = conn.assigns.current_user
    token = get_session(conn, :user_session_token)
    key = Security.status(user, token).setup_key
    code = key |> Base.decode32!(padding: false) |> NimbleTOTP.verification_code()
    enabled = post(conn, "/account/2fa/confirm", %{security: %{code: code}})
    html = html_response(enabled, 200)
    assert html =~ "请立即保存恢复码"
    assert Security.enabled?(user)
    assert get_session(enabled, :user_session_token) != token
    page = enabled |> recycle() |> get("/account")
    refute page.resp_body =~ "请立即保存恢复码"
    assert page.resp_body =~ "剩余恢复码：10"
  end
end
