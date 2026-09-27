defmodule TeslaMateWeb.CaptchaSettingsTest do
  use TeslaMateWeb.ConnCase, async: false
  alias TeslaMate.{Accounts, Repo}
  alias TeslaMate.Auth.{Captcha, CaptchaSettings, CaptchaVendors}
  alias TeslaMate.Auth.CaptchaSettings.Record
  alias TeslaMateWeb.Plugs.LoginRateLimit

  @aliyun %{"provider" => "aliyun", "region" => "cn", "prefix" => "identity", "scene_id" => "scene-test", "access_key_id" => "ram-id", "access_key_secret" => "ram-private-secret"}
  @tencent %{"provider" => "tencent", "app_id" => "123456789", "app_secret_key" => "app-private-secret", "secret_id" => "cloud-id", "secret_key" => "cloud-private-secret"}
  @vars %{"TESLAMATE_TURNSTILE_ENABLED" => "true", "TESLAMATE_TURNSTILE_SITE_KEY" => "cf-public", "TESLAMATE_TURNSTILE_SECRET_KEY" => "cf-private", "TESLAMATE_TURNSTILE_HOSTNAMES" => "vehicles.example.com"}

  defmodule HTTPStub do
    def post(url, body, opts) do
      send(self(), {:captcha_request, url, body, opts})
      Process.get(:captcha_result, {:error, :timeout})
    end
  end

  setup do
    start_supervised!(TeslaMate.Vault)
    previous = Map.new(@vars, fn {key, _} -> {key, System.get_env(key)} end)
    client = Application.get_env(:teslamate, :captcha_http_client)
    System.put_env(@vars)
    Application.put_env(:teslamate, :captcha_http_client, HTTPStub)
    LoginRateLimit.ensure_started()
    :ets.delete_all_objects(:teslamate_login_rate_limits)
    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
      if client, do: Application.put_env(:teslamate, :captcha_http_client, client), else: Application.delete_env(:teslamate, :captcha_http_client)
      :ets.delete_all_objects(:teslamate_login_rate_limits)
    end)
    :ok
  end

  defp response(data), do: Process.put(:captcha_result, {:ok, %{status: 200, body: Jason.encode!(data)}})
  defp accept("aliyun"), do: response(%{"Success" => true, "Code" => "Success", "Result" => %{"VerifyResult" => true, "VerifyCode" => "T001"}})
  defp accept("tencent"), do: response(%{"Response" => %{"CaptchaCode" => 1}})
  defp proof(provider, revision), do: %{"captcha_provider" => provider, "captcha_revision" => to_string(revision), "captcha_token" => "opaque-token+/=", "captcha_randstr" => "random"}
  defp save(user, attrs) do
    {:verify, token} = CaptchaSettings.prepare(user, attrs)
    {:ok, draft} = CaptchaSettings.draft(user, token)
    accept(attrs["provider"])
    assert {:ok, :saved} = CaptchaSettings.verify_and_save(user, token, proof(draft.provider, draft.revision), "192.0.2.1")
    token
  end

  test "upgrade preserves legacy policy; verification failure never changes active credentials", %{current_user: user} do
    before = CaptchaSettings.active()
    assert before.provider == "cloudflare"
    {:verify, token} = CaptchaSettings.prepare(user, @aliyun)
    refute token =~ "ram-private-secret"
    assert {:error, :unavailable} = CaptchaSettings.verify_and_save(user, token, proof("aliyun", 0), "192.0.2.1")
    assert CaptchaSettings.active() == before
    assert Repo.get!(Record, 1).profiles == nil
  end

  test "verified profiles are encrypted and retained when switching without reentering keys", %{current_user: user} do
    old_token = save(user, @aliyun)
    assert CaptchaSettings.active().provider == "aliyun"
    assert {:error, :expired} = CaptchaSettings.draft(user, old_token)
    save(user, @tencent)
    assert {:ok, :saved} = CaptchaSettings.prepare(user, %{"provider" => "aliyun", "access_key_secret" => ""})
    assert CaptchaSettings.active().config["access_key_secret"] == @aliyun["access_key_secret"]
    assert {:ok, :saved} = CaptchaSettings.prepare(user, %{"provider" => "tencent"})
    assert CaptchaSettings.active().config["app_secret_key"] == @tencent["app_secret_key"]
    System.delete_env("TESLAMATE_TURNSTILE_SECRET_KEY")
    assert {:ok, :saved} = CaptchaSettings.prepare(user, %{"provider" => "cloudflare"})
    assert CaptchaSettings.active().config["secret_key"] == "cf-private"
    prefs = inspect(CaptchaSettings.preferences())
    for secret <- ["cf-private", "ram-private-secret", "app-private-secret", "cloud-private-secret"] do
      refute prefs =~ secret
      refute inspect(Repo.get!(Record, 1)) =~ secret
      [[encrypted]] = Repo.query!("SELECT profiles FROM private.captcha_settings").rows
      refute :binary.match(encrypted, secret) != :nomatch
    end
  end

  test "changed credentials need a new challenge; concurrent drafts cannot overwrite a newer save", %{current_user: user} do
    save(user, @aliyun)
    {:verify, token} = CaptchaSettings.prepare(user, Map.put(@aliyun, "access_key_secret", "replacement-secret"))
    assert CaptchaSettings.active().config["access_key_secret"] == "ram-private-secret"
    save(user, @tencent)
    accept("aliyun")
    assert {:error, :expired} = CaptchaSettings.verify_and_save(user, token, proof("aliyun", 1), "192.0.2.1")
    assert CaptchaSettings.active().provider == "tencent"
  end

  test "member, malformed fields, modified draft and wrong revision cannot apply", %{current_user: admin} do
    member = TeslaMate.AccountFixtures.member()
    assert {:error, :forbidden} = CaptchaSettings.prepare(member, @aliyun)
    assert {:error, :configuration} = CaptchaSettings.prepare(admin, Map.put(@aliyun, "region", "http://internal"))
    assert {:error, :configuration} = CaptchaSettings.prepare(admin, Map.put(@tencent, "secret_id", "header\ninjection"))
    assert {:error, :configuration} = CaptchaSettings.prepare(admin, %{"provider" => "unsupported"})
    {:verify, token} = CaptchaSettings.prepare(admin, @aliyun)
    assert {:error, :expired} = CaptchaSettings.draft(member, token)
    assert {:error, :expired} = CaptchaSettings.draft(admin, token <> "tampered")
    accept("aliyun")
    assert {:error, :invalid} = CaptchaSettings.verify_and_save(admin, token, proof("aliyun", 3), "192.0.2.1")
    assert {:error, :invalid} = CaptchaSettings.verify_and_save(admin, token, proof("tencent", 0), "192.0.2.1")
    refute_received {:captcha_request, _, _, _}
  end

  test "drafts expire after ten minutes", %{current_user: user} do
    token = Phoenix.Token.encrypt(TeslaMateWeb.Endpoint, "captcha-configuration-v1", %{user_id: user.id, provider: "aliyun", config: @aliyun, revision: 0}, signed_at: System.system_time(:second) - 601)
    assert {:error, :expired} = CaptchaSettings.draft(user, token)
  end

  test "admin verification page contains only public fields and encrypted draft; route CSP is scoped", %{conn: conn} do
    page = post(conn, "/admin/captcha", %{"captcha_settings" => @aliyun})
    html = html_response(page, 200)
    assert html =~ "data-provider=\"aliyun\""
    refute html =~ "ram-private-secret"
    refute html =~ "ram-id"
    assert get_resp_header(page, "cache-control") == ["no-store"]
    [csp] = get_resp_header(page, "content-security-policy")
    assert csp =~ "https://o.alicdn.com"
    refute csp =~ "challenges.cloudflare.com"
    {:ok, document} = Floki.parse_document(html)
    [token] = Floki.attribute(document, "input[name=captcha_setup_token]", "value")
    accept("aliyun")
    saved = post(recycle(page), "/admin/captcha/verify", Map.put(proof("aliyun", 0), "captcha_setup_token", token))
    assert redirected_to(saved) == "/admin/settings#captcha-settings"
    assert CaptchaSettings.active().provider == "aliyun"
    public = get(build_conn(), "/sign_in")
    assert hd(get_resp_header(public, "content-security-policy")) =~ "https://o.alicdn.com"
    home = get(build_conn(), "/")
    refute hd(get_resp_header(home, "content-security-policy")) =~ "https://o.alicdn.com"
  end

  @tag platform_role: :member
  test "members cannot reach either configuration endpoint", %{conn: conn} do
    for path <- ["/admin/captcha", "/admin/captcha/verify"] do
      denied = post(conn, path, %{"captcha_settings" => @aliyun})
      assert denied.status in [302, 403]
    end
    assert CaptchaSettings.active().provider == "cloudflare"
  end

  test "selected vendor gates registration and a failed login on the server", %{current_user: user} do
    save(user, @tencent)
    {:ok, _} = Accounts.set_registration(user, true)
    email = "captcha-registration@example.com"
    credentials = %{"user" => %{"email" => email, "name" => "Member", "password" => "correct horse battery staple 42", "password_confirmation" => "correct horse battery staple 42"}}
    denied = post(build_conn(), "/register", credentials)
    assert html_response(denied, 422) =~ "data-provider=\"tencent\""
    refute Repo.get_by(TeslaMate.Accounts.User, email: email)
    accept("tencent")
    registered = post(build_conn(), "/register", Map.merge(credentials, proof("tencent", 1)))
    assert get_session(registered, :user_session_token)
    failed = post(build_conn(), "/sign_in", %{"user" => %{"email" => email, "password" => "wrong"}})
    assert html_response(failed, 422) =~ "data-provider=\"tencent\""
    blocked = post(build_conn(), "/sign_in", credentials)
    assert html_response(blocked, 422) =~ "请完成人机验证"
    refute get_session(blocked, :user_session_token)
    accept("tencent")
    logged_in = post(build_conn(), "/sign_in", Map.merge(credentials, proof("tencent", 1)))
    assert get_session(logged_in, :user_session_token)
  end

  test "server rejects test mode, expired, reused, disaster, malformed and HTTP-only success" do
    for data <- [%{"Success" => true}, %{"Success" => true, "Code" => "Success", "Result" => %{"VerifyResult" => false, "VerifyCode" => "F019"}}] do
      response(data)
      assert {:error, _} = CaptchaVendors.verify("aliyun", @aliyun, proof("aliyun", 0), "192.0.2.1")
    end
    response(%{"Result" => %{"VerifyResult" => true, "VerifyCode" => "T005"}})
    assert {:error, :test_mode} = CaptchaVendors.verify("aliyun", @aliyun, proof("aliyun", 0), "192.0.2.1")
    for code <- [0, 8, 9, 15, 16, 100] do
      response(%{"Response" => %{"CaptchaCode" => code}})
      assert {:error, _} = CaptchaVendors.verify("tencent", @tencent, proof("tencent", 0), "192.0.2.1")
    end
    accept("tencent")
    for token <- [nil, %{}, "", String.duplicate("x", 32_769), "trerror_fake"] do
      assert {:error, :invalid} = CaptchaVendors.verify("tencent", @tencent, Map.put(proof("tencent", 0), "captcha_token", token), "192.0.2.1")
    end
    Process.put(:captcha_result, {:ok, %{status: 200, body: "not-json"}})
    assert {:error, :unavailable} = CaptchaVendors.verify("tencent", @tencent, proof("tencent", 0), "192.0.2.1")
  end

  test "vendor requests use fixed endpoints, unchanged proof, server scene and trusted IP" do
    now = ~U[2026-09-27 00:00:00Z]
    {url, body, headers} = CaptchaVendors.request("aliyun", @aliyun, "opaque+/=", nil, "192.0.2.8", now)
    assert url == "https://captcha.cn-shanghai.aliyuncs.com/"
    assert URI.decode_query(body) == %{"CaptchaVerifyParam" => "opaque+/=", "SceneId" => "scene-test"}
    assert List.keyfind(headers, "x-acs-version", 0) == {"x-acs-version", "2023-03-05"}
    {url, body, _} = CaptchaVendors.request("tencent", @tencent, "ticket", "random", "192.0.2.8", now)
    assert url == "https://captcha.tencentcloudapi.com/"
    assert Jason.decode!(body)["UserIp"] == "192.0.2.8"
    assert Jason.decode!(body)["CaptchaType"] == 9
    assert Jason.decode!(body)["CaptchaAppId"] == 123456789
  end

  test "TC3 and ACS3 signing match independently generated fixed vectors" do
    headers = [{"content-type", "application/json; charset=utf-8"}, {"host", "captcha.tencentcloudapi.com"}, {"x-tc-action", "DescribeCaptchaResult"}]
    auth = CaptchaVendors.tencent_authorization(%{"secret_id" => "test-id", "secret_key" => "test-secret"}, headers, "{}", ~U[2026-09-27 00:00:00Z])
    assert String.ends_with?(auth, "Signature=7a71a912d6dc8d93f1b86115139d00dcdd1ad706d89c8f327440a2223439eb72")
    body = "SceneId=test"
    hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    headers = [{"host", "captcha.cn-shanghai.aliyuncs.com"}, {"x-acs-action", "VerifyIntelligentCaptcha"}, {"x-acs-content-sha256", hash}, {"x-acs-date", "2026-09-27T00:00:00Z"}, {"x-acs-signature-nonce", "test-nonce"}, {"x-acs-version", "2023-03-05"}]
    auth = CaptchaVendors.aliyun_authorization(%{"access_key_id" => "test-id", "access_key_secret" => "test-secret"}, headers, body)
    assert String.ends_with?(auth, "Signature=a6c2000eda36d6945559103f39c06f1837e21794e8051f56092bc3b3a7264b2b")
  end

  test "credential and proof params are filtered from request logs" do
    params = %{"captcha_settings" => @aliyun, "captcha_token" => "proof", "captcha_randstr" => "random", "captcha_setup_token" => "encrypted"}
    filtered = Phoenix.Logger.filter_values(params)
    assert Enum.all?(filtered, fn {_key, value} -> value == "[FILTERED]" end)
  end
end
