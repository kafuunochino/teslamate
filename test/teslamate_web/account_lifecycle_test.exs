defmodule TeslaMateWeb.AccountLifecycleTest do
  use TeslaMateWeb.ConnCase, async: false
  alias TeslaMate.{Accounts, Repo}
  @password "correct horse battery staple 42"

  setup %{current_user: user} do
    start_supervised!(TeslaMate.Vault)

    current =
      user
      |> Ecto.Changeset.change(password_hash: Accounts.Password.hash(@password))
      |> Repo.update!()

    %{current_user: current}
  end

  defp member do
    {:ok, user} =
      Accounts.register_user(%{
        email: "delete-#{System.unique_integer([:positive])}@example.com",
        name: "Delete Test",
        password: @password,
        password_confirmation: @password
      })

    user
  end

  defp confirmation(user, changes \\ %{}) do
    Map.merge(%{"email" => user.email, "password" => @password, "acknowledge" => "true"}, changes)
  end

  test "user management has fixed administrator identity and no promotion controls", c do
    user = member()
    {:ok, view, html} = live(c.conn, "/admin/users")
    assert html =~ "系统唯一管理员"
    refute html =~ "设为管理员"
    refute html =~ "降为用户"
    refute has_element?(view, "#user-row-#{c.current_user.id} button[phx-click=prepare_delete]")
    refute has_element?(view, "#user-row-#{c.current_user.id} button[phx-click=update_user]")
    assert has_element?(view, "#user-row-#{user.id} button[phx-click=prepare_delete]")
    render_click(view, "update_user", %{"id" => user.id, "role" => "admin", "status" => "active"})
    assert Accounts.get_user!(user.id).role == :member
    refute Accounts.authorized_admin?(Accounts.get_user!(user.id))
  end

  test "administrator deletion requires two stages and binds confirmation to the selected target",
       c do
    target = member()
    other = member()
    {:ok, view, _} = live(c.conn, "/admin/users")

    render_submit(view, "confirm_delete", %{
      "id" => target.id,
      "confirmation" => confirmation(target)
    })

    assert Accounts.get_user(target.id)
    refute has_element?(view, "#admin-delete-form")
    view |> element("#user-row-#{target.id} button[phx-click=prepare_delete]") |> render_click()
    assert has_element?(view, "#admin-delete-form")

    render_submit(view, "confirm_delete", %{
      "id" => other.id,
      "confirmation" => confirmation(other)
    })

    assert Accounts.get_user(target.id)
    assert Accounts.get_user(other.id)

    view
    |> form("#admin-delete-form", confirmation: confirmation(target, %{"password" => "wrong"}))
    |> render_submit()

    assert Accounts.get_user(target.id)
    view |> form("#admin-delete-form", confirmation: confirmation(target)) |> render_submit()
    refute Accounts.get_user(target.id)
    assert Accounts.get_user(other.id)
    refute has_element?(view, "#admin-delete-form")
    assert render(view) =~ "车辆历史已保留"
  end

  test "primary account shows protected closure button and rejects forged requests", c do
    html = c.conn |> get("/account") |> html_response(200)
    assert html =~ ~s(id="system-admin-deletion-disabled")
    refute html =~ ~s(id="account-deletion-form")
    response = post(c.conn, "/account/deletion", %{confirmation: confirmation(c.current_user)})
    assert redirected_to(response) == "/account#account-deletion"
    refute Accounts.get_user!(c.current_user.id).deletion_scheduled_at
    assert Accounts.get_user_by_session_token(get_session(c.conn, :user_session_token))
  end

  @tag platform_role: :member
  test "member closure is scoped to self, revokes sessions and full HTTP login cancels it", c do
    other = member()
    html = c.conn |> get("/account") |> html_response(200)
    assert html =~ ~s(id="account-deletion-form")
    assert html =~ "七天冷静期"
    refute html =~ ~s(id="system-admin-deletion-disabled")

    response =
      post(c.conn, "/account/deletion", %{confirmation: confirmation(other), id: other.id})

    assert redirected_to(response) == "/account#account-deletion"
    refute Accounts.get_user!(c.current_user.id).deletion_scheduled_at
    response = post(c.conn, "/account/deletion", %{confirmation: confirmation(c.current_user)})
    assert redirected_to(response) == "/sign_in"
    assert Accounts.get_user!(c.current_user.id).deletion_scheduled_at
    refute Accounts.get_user_by_session_token(get_session(c.conn, :user_session_token))
    assert redirected_to(get(c.conn, "/account")) == "/sign_in"
    post(build_conn(), "/sign_in", %{user: %{email: c.current_user.email, password: "wrong"}})
    assert Accounts.get_user!(c.current_user.id).deletion_scheduled_at

    login =
      post(build_conn(), "/sign_in", %{user: %{email: c.current_user.email, password: @password}})

    assert redirected_to(login) == "/"
    assert Phoenix.Flash.get(login.assigns.flash, :success) =~ "已取消账号注销"
    refute Accounts.get_user!(c.current_user.id).deletion_scheduled_at
    assert Accounts.get_user(other.id)
  end

  @tag platform_role: :member
  test "members cannot reach administrator deletion UI", c do
    assert get(c.conn, "/admin/users").status == 404

    assert {:error, :forbidden} =
             Accounts.Lifecycle.delete_account(
               c.current_user,
               get_session(c.conn, :user_session_token),
               TeslaMate.AccountFixtures.system_admin().id,
               confirmation(c.current_user)
             )
  end
end
