defmodule TeslaMateWeb.AdminUsersLiveTest do
  use TeslaMateWeb.ConnCase, async: false

  alias TeslaMate.{Accounts, Log}

  setup do
    id = System.unique_integer([:positive])
    password = "correct horse battery staple 42"

    {:ok, member} =
      Accounts.register_user(%{
        email: "binding-#{id}@example.com",
        name: "车辆授权测试用户",
        password: password,
        password_confirmation: password
      })

    {:ok, car} =
      Log.create_car(%{
        eid: id,
        vid: id,
        vin: "BINDING#{id}",
        name: "归属测试车",
        model: "3"
      })

    %{member: member, car: car}
  end

  test "granting vehicle access survives reloading and can be revoked", %{
    conn: conn,
    member: member,
    car: car
  } do
    {:ok, view, _html} = live(conn, "/admin/users")

    view
    |> form("form[phx-submit='grant_car']",
      binding: %{user_id: to_string(member.id), car_id: to_string(car.id)}
    )
    |> render_submit()

    assert render(view) =~ "车辆权限已授予"
    assert Accounts.can_access_car?(member, car.id)

    selector =
      "button[phx-click='revoke_car'][phx-value-user-id='#{member.id}'][phx-value-car-id='#{car.id}']"

    {:ok, reopened, _html} = live(conn, "/admin/users")
    assert has_element?(reopened, selector)

    reopened |> element(selector) |> render_click()
    refute Accounts.can_access_car?(member, car.id)

    {:ok, refreshed, _html} = live(conn, "/admin/users")
    refute has_element?(refreshed, selector)
    assert has_element?(refreshed, "h1", "用户与车辆权限")
  end

  test "creating and revoking a vehicle claim survives page reloads", %{
    conn: conn,
    current_user: admin,
    car: car
  } do
    {:ok, view, _html} = live(conn, "/admin/users")

    view
    |> form("form[phx-submit='create_claim']",
      claim: %{car_id: to_string(car.id), hours: "1"}
    )
    |> render_submit()

    assert has_element?(view, "#new-claim-code")
    [claim] = Accounts.list_vehicle_claims(admin)
    assert claim.car.id == car.id

    {:ok, reopened, _html} = live(conn, "/admin/users")
    refute has_element?(reopened, "#new-claim-code")

    reopened
    |> element("button[phx-click='revoke_claim'][phx-value-id='#{claim.id}']")
    |> render_click()

    {:ok, refreshed, _html} = live(conn, "/admin/users")
    assert has_element?(refreshed, "h1", "用户与车辆权限")
    [revoked] = Accounts.list_vehicle_claims(admin)
    assert revoked.car.id == car.id
    assert revoked.revoked_at
  end
end
