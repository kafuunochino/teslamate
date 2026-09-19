defmodule TeslaMateWeb.PortalRegistrationTest do
  use TeslaMateWeb.ConnCase, async: false
  alias TeslaMate.{Accounts, Repo}
  alias TeslaMate.Accounts.Invitations

  defp visitor, do: %{build_conn() | remote_ip: {192, 0, 2, 213}}

  test "public root is a fictional product portal for visitors and signed-in users", %{
    conn: conn,
    current_user: user
  } do
    for connection <- [build_conn(), conn] do
      html = connection |> get("/") |> html_response(200)
      assert html =~ "特友会"
      assert html =~ "虚拟数据演示"
      assert html =~ "非真实地图、地点或车辆记录"
      assert html =~ ~s(href="/sign_in")
      assert html =~ ~s(href="/dashboard")
      refute html =~ user.email
      refute html =~ user.name
      refute html =~ ~s(id="platform-sidebar")
      refute html =~ ~s(id="vehicle-map")
    end

    assert redirected_to(get(build_conn(), "/dashboard")) == "/sign_in"
  end

  test "portal registration action respects closure and invitation policy", %{current_user: admin} do
    closed = get(build_conn(), "/").resp_body
    assert closed =~ "当前暂未开放新账号注册"
    refute closed =~ ~s(href="/register")
    {:ok, _} = Accounts.set_registration_policy(admin, true, true)
    invited = get(build_conn(), "/").resp_body
    assert invited =~ ~s(href="/register")
    assert invited =~ "当前为邀请内测"
  end

  test "actual UI previews are identical for visitors and users and never query the database", %{
    conn: conn,
    current_user: user
  } do
    handler = "portal-preview-#{System.unique_integer([:positive])}"
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:teslamate, :repo, :query],
        fn _, _, _, pid ->
          if self() == pid, do: send(pid, :preview_database_query)
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    for page <- ["home", "trips", "trip", "charging"] do
      response = get(build_conn(), "/preview/#{page}?car=123&user=123")
      html = html_response(response, 200)
      assert html == html_response(get(conn, "/preview/#{page}"), 200)
      assert html =~ "虚拟数据演示"
      if page != "trip", do: assert(html =~ "Model Y · 示例车辆")

      if page == "trip" do
        assert html =~ "portal-route-map"
        assert html =~ "虚拟路线演示"
        assert html =~ "146.0 Wh/km"
        assert html =~ "6.22 kWh"
      end

      refute html =~ user.email
      refute html =~ user.name
      dom = Floki.parse_document!(html)
      assert Floki.find(dom, "body[inert]") != []
      assert Floki.find(dom, ".metric-card") != []
      assert Floki.find(dom, "script") == []
      [policy] = get_resp_header(response, "content-security-policy")
      assert policy =~ "connect-src 'none'"
      assert policy =~ "script-src 'none'"
      assert policy =~ "frame-ancestors 'self'"
    end

    assert get(build_conn(), "/preview/vehicles").status == 404
    refute_received :preview_database_query
  end

  test "direct POST cannot bypass required invitation, forged policy, or reuse", %{
    current_user: admin
  } do
    {:ok, _} = Accounts.set_registration_policy(admin, true, true)
    {:ok, [code]} = Invitations.generate(admin, 1)
    page = get(build_conn(), "/register").resp_body |> Floki.parse_document!()
    assert Floki.find(page, "input[name='user[invitation_code]'][required]") != []

    params = %{
      "email" => "portal-invite@example.com",
      "name" => "New User",
      "password" => "correct horse battery staple 42",
      "password_confirmation" => "correct horse battery staple 42",
      "require_invitation" => "false",
      "role" => "admin",
      "is_system_admin" => "true"
    }

    count = Repo.aggregate(Accounts.User, :count)

    for invalid <- [nil, "", "invalid", %{"nested" => "invalid"}] do
      result = post(visitor(), "/register", %{user: Map.put(params, "invitation_code", invalid)})
      assert result.status == 422
      assert result.resp_body =~ "邀请码无效"
    end

    assert Repo.aggregate(Accounts.User, :count) == count
    assert Invitations.valid?(code)
    success = post(visitor(), "/register", %{user: Map.put(params, "invitation_code", code)})
    assert redirected_to(success) == "/dashboard"
    assert Accounts.get_user_by_email(params["email"]).role == :member
    replay = params |> Map.put("invitation_code", code) |> Map.put("email", "replay@example.com")
    assert post(visitor(), "/register", %{user: replay}).status == 422
    refute Accounts.get_user_by_email("replay@example.com")
  end

  test "system settings saves invitation policy and manages single-display code batches", %{
    conn: conn,
    current_user: admin
  } do
    {:ok, view, _} = live(conn, "/admin/settings")

    view
    |> form("form[phx-submit=registration_policy]",
      registration: %{enabled: "true", require_invitation: "true"}
    )
    |> render_submit()

    assert %{allow_registration: true, require_invitation: true} = Accounts.registration_policy()

    html =
      view
      |> form("form[phx-submit=generate_invitations]", invitation: %{quantity: "3"})
      |> render_submit()

    codes =
      html
      |> Floki.parse_document!()
      |> Floki.find("#invitation-codes")
      |> Floki.text()
      |> String.split()

    assert length(codes) == 3
    assert %{total: 3, used: 0} = Invitations.list(admin)
    html = render_click(view, "clear_invitation_codes")
    refute html =~ hd(codes)
    {:ok, _, reloaded} = live(conn, "/admin/settings")
    refute reloaded =~ hd(codes)

    assert Phoenix.Logger.filter_values(%{"invitation_code" => hd(codes)}) == %{
             "invitation_code" => "[FILTERED]"
           }
  end

  @tag platform_role: :member
  test "members cannot access settings or invitation administration", %{conn: conn} do
    assert get(conn, "/admin/settings").status == 404
    assert get(conn, "/settings").status == 404
  end
end
