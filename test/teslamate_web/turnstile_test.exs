defmodule TeslaMateWeb.TurnstileTest do
  use TeslaMateWeb.ConnCase, async: false

  alias TeslaMate.{Accounts, Repo}
  alias TeslaMate.Accounts.{Authenticator, User}
  alias TeslaMate.Auth.Turnstile
  alias TeslaMateWeb.Plugs.LoginRateLimit

  @password "correct horse battery staple 42"
  @hostname "vehicles.example.com"
  @vars %{
    "TESLAMATE_TURNSTILE_ENABLED" => "true",
    "TESLAMATE_TURNSTILE_SITE_KEY" => "test-public-key",
    "TESLAMATE_TURNSTILE_SECRET_KEY" => "test-private-key",
    "TESLAMATE_TURNSTILE_HOSTNAMES" => @hostname
  }

  defmodule HTTPStub do
    def post(url, body, opts) do
      send(self(), {:siteverify, url, URI.decode_query(body), opts})
      Process.get(:siteverify_result, {:error, :timeout})
    end
  end

  setup %{current_user: user} do
    previous = Map.new(@vars, fn {key, _} -> {key, System.get_env(key)} end)
    client = Application.get_env(:teslamate, :turnstile_http_client)
    System.put_env(@vars)
    Application.put_env(:teslamate, :turnstile_http_client, HTTPStub)
    LoginRateLimit.ensure_started()
    :ets.delete_all_objects(:teslamate_login_rate_limits)
    start_supervised!(TeslaMate.Vault)

    user =
      user
      |> Ecto.Changeset.change(password_hash: Accounts.Password.hash(@password))
      |> Repo.update!()

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      if client,
        do: Application.put_env(:teslamate, :turnstile_http_client, client),
        else: Application.delete_env(:teslamate, :turnstile_http_client)

      :ets.delete_all_objects(:teslamate_login_rate_limits)
    end)

    %{current_user: user}
  end

  defp accepted(action, overrides \\ %{}) do
    result = Map.merge(%{"success" => true, "hostname" => @hostname, "action" => action}, overrides)
    Process.put(:siteverify_result, {:ok, %{status: 200, body: Jason.encode!(result)}})
  end

  defp credentials(user, password \\ @password),
    do: %{"user" => %{"email" => user.email, "password" => password}}

  defp with_token(params), do: Map.put(params, "cf-turnstile-response", "test-response")

  test "first valid password needs no challenge", %{current_user: user} do
    refute get(build_conn(), "/sign_in").resp_body =~ "data-turnstile-widget"
    response = post(build_conn(), "/sign_in", credentials(user))
    assert get_session(response, :user_session_token)
    refute_received {:siteverify, _, _, _}
  end

  test "one failure gates retries across fresh cookies and IP changes", %{current_user: user} do
    failed = post(build_conn(), "/sign_in", credentials(user, "wrong"))
    assert html_response(failed, 422) =~ "data-turnstile-widget"
    assert get(build_conn(), "/sign_in").resp_body =~ "data-turnstile-widget"

    # A fresh connection has no session cookies. Changing the IP still leaves
    # the email failure marker in force before any password is authenticated.
    for ip <- [{127, 0, 0, 1}, {192, 0, 2, 10}] do
      response = post(%{build_conn() | remote_ip: ip}, "/sign_in", credentials(user))
      assert html_response(response, 422) =~ "请完成人机验证"
      refute get_session(response, :user_session_token)
    end

    accepted("login")
    response = post(build_conn(), "/sign_in", with_token(credentials(user)))
    assert get_session(response, :user_session_token)
    refute LoginRateLimit.challenge_required?("127.0.0.1", user.email)
    assert LoginRateLimit.hit_count(:ip, "127.0.0.1") > 0
  end

  test "old failure markers expire; registration attempts do not trigger login challenges" do
    ip = "192.0.2.12"
    LoginRateLimit.record_failure(ip, "registration:user@example.com")
    refute LoginRateLimit.challenge_required?(ip)
    old = System.system_time(:second) - TeslaMateWeb.Config.login_window_seconds() - 1
    :ets.insert(:teslamate_login_rate_limits, {{:challenge_ip, ip}, old})
    refute LoginRateLimit.challenge_required?(ip)
    LoginRateLimit.record_login_failure(ip, "user@example.com")
    assert LoginRateLimit.challenge_required?(ip)
  end

  test "registration always validates before account creation", %{current_user: admin} do
    {:ok, _} = Accounts.set_registration(admin, true)
    html = get(build_conn(), "/register") |> html_response(200)
    assert html =~ "data-turnstile-widget"
    assert html =~ "test-public-key"
    refute html =~ "test-private-key"
    email = "turnstile-new@example.com"

    params = %{
      "user" => %{
        "name" => "New Member",
        "email" => email,
        "password" => @password,
        "password_confirmation" => @password
      }
    }

    assert post(build_conn(), "/register", params).status == 422
    refute Repo.get_by(User, email: email)
    refute_received {:siteverify, _, _, _}
    accepted("register")
    registered = post(build_conn(), "/register", with_token(params))
    assert get_session(registered, :user_session_token)
    assert Repo.get_by!(User, email: email).role == :member
  end

  test "closed registration stays closed even with a token" do
    assert get(build_conn(), "/register").status == 404
    assert post(build_conn(), "/register", with_token(%{"user" => %{}})).status == 404
    refute_received {:siteverify, _, _, _}
  end

  test "failed human verification cannot authenticate correct credentials", %{current_user: user} do
    LoginRateLimit.record_login_failure("127.0.0.1", user.email)
    accepted("login", %{"success" => false, "error-codes" => ["timeout-or-duplicate"]})
    response = post(build_conn(), "/sign_in", with_token(credentials(user)))
    assert response.status == 422
    refute get_session(response, :user_session_token)
  end

  test "checks hostname and action and fails closed on invalid replies and transport errors" do
    for overrides <- [
          %{"success" => false},
          %{"success" => "true"},
          %{"hostname" => "attacker.example.com"},
          %{"action" => "register"}
        ] do
      accepted("login", overrides)
      assert {:error, :invalid} = Turnstile.verify("response", "192.0.2.1", "login")
    end

    for response <- [
          {:ok, %{status: 200, body: "not-json"}},
          {:ok, %{status: 503, body: "unavailable"}},
          {:error, :timeout}
        ] do
      Process.put(:siteverify_result, response)
      assert {:error, :unavailable} = Turnstile.verify("response", "192.0.2.1", "login")
    end
  end

  test "missing, malformed and oversized tokens never call Cloudflare" do
    for value <- [nil, "", %{}, ["token"], String.duplicate("x", 2049)] do
      assert {:error, :invalid} = Turnstile.verify(value, "192.0.2.1", "login")
    end

    refute_received {:siteverify, _, _, _}
  end

  test "server supplies secret, real IP and bounded timeouts to the fixed endpoint" do
    accepted("login")
    assert :ok = Turnstile.verify("response", "2001:db8::42", "login")
    assert_received {:siteverify, url, body, opts}
    assert url == "https://challenges.cloudflare.com/turnstile/v0/siteverify"
    assert body == %{"secret" => "test-private-key", "response" => "response", "remoteip" => "2001:db8::42"}
    assert opts[:receive_timeout] == 5000
    assert opts[:pool_timeout] == 1000
  end

  test "enabled but incomplete configuration cannot bypass protection", %{current_user: user} do
    LoginRateLimit.record_login_failure("127.0.0.1", user.email)
    System.delete_env("TESLAMATE_TURNSTILE_SECRET_KEY")
    response = post(build_conn(), "/sign_in", with_token(credentials(user)))
    assert html_response(response, 422) =~ "人机验证暂时不可用"
    refute get_session(response, :user_session_token)
    refute_received {:siteverify, _, _, _}
  end

  test "2FA remains mandatory and a failed code requires a new human verification", %{current_user: user} do
    secret = NimbleTOTP.secret()
    Repo.insert!(%Authenticator{user_id: user.id, secret: secret, enabled_at: DateTime.utc_now()})
    first = post(build_conn(), "/sign_in", credentials(user))
    assert redirected_to(first) == "/sign_in/verify"
    refute get_session(first, :user_session_token)
    failed = first |> recycle() |> post("/sign_in/verify", %{"verification" => %{"code" => "invalid"}})
    assert html_response(failed, 422) =~ "data-turnstile-widget"
    code = NimbleTOTP.verification_code(secret)
    params = %{"verification" => %{"code" => code}}
    rejected = failed |> recycle() |> post("/sign_in/verify", params)
    assert rejected.status == 422
    refute get_session(rejected, :user_session_token)
    accepted("login_2fa")
    success = rejected |> recycle() |> post("/sign_in/verify", with_token(params))
    assert get_session(success, :user_session_token)
  end

  test "only auth pages permit the challenge frame and responses are redacted", %{conn: conn} do
    [auth_policy] = get_resp_header(get(build_conn(), "/sign_in"), "content-security-policy")
    assert auth_policy =~ "frame-src https://challenges.cloudflare.com"
    assert auth_policy =~ "frame-ancestors 'none'"
    [account_policy] = get_resp_header(get(conn, "/account"), "content-security-policy")
    refute account_policy =~ "challenges.cloudflare.com"
    assert account_policy =~ "frame-src 'none'"
    assert Phoenix.Logger.filter_values(%{"cf-turnstile-response" => "response"}) ==
             %{"cf-turnstile-response" => "[FILTERED]"}
  end
end
