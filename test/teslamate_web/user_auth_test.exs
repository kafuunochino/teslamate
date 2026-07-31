defmodule TeslaMateWeb.UserAuthTest do
  use TeslaMateWeb.ConnCase, async: false

  alias TeslaMate.Accounts

  @valid_password "correct horse battery staple 42"

  @tag auth: false
  test "unauthenticated users are redirected to the platform sign-in", %{conn: conn} do
    conn = get(conn, "/")
    assert redirected_to(conn) == "/sign_in"
  end

  @tag auth: false
  test "a user can register, sign in and receives no vehicle access", %{conn: conn} do
    email = "web-#{System.unique_integer([:positive])}@example.com"

    conn =
      post(conn, "/register", %{
        "user" => %{
          "email" => email,
          "name" => "Web User",
          "password" => @valid_password,
          "password_confirmation" => @valid_password
        }
      })

    assert redirected_to(conn) == "/"
    user = Accounts.get_user_by_email(email)
    assert user.role == :member
    assert Accounts.list_accessible_cars(user) == []
    assert get_session(conn, :user_session_token)
  end

  @tag platform_role: :member
  test "member accounts cannot access administrator pages", %{conn: conn} do
    conn = get(conn, "/admin/users")
    assert conn.status == 404
  end

  test "administrator can access the user management page", %{conn: conn} do
    assert {:ok, _view, html} = live(conn, "/admin/users")
    assert html =~ "用户与车辆权限"
  end
end
