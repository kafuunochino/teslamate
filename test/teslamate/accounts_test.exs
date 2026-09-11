defmodule TeslaMate.AccountsTest do
  use TeslaMate.DataCase, async: false

  alias TeslaMate.{Accounts, Fleet, Log, Repo}
  alias TeslaMate.Accounts.{UserSession, VehicleClaim}

  @valid_password "correct horse battery staple 42"

  setup do
    {:ok, admin} =
      Accounts.bootstrap_admin(%{
        email: unique_email("admin"),
        name: "平台管理员",
        password: @valid_password,
        password_confirmation: @valid_password
      })

    {:ok, member} =
      Accounts.register_user(%{
        email: unique_email("member"),
        name: "车辆用户",
        password: @valid_password,
        password_confirmation: @valid_password
      })

    {:ok, other_member} =
      Accounts.register_user(%{
        email: unique_email("other"),
        name: "其他用户",
        password: @valid_password,
        password_confirmation: @valid_password
      })

    {:ok, car} =
      Log.create_car(%{
        efficiency: 0.153,
        eid: System.unique_integer([:positive]),
        model: "3",
        vid: System.unique_integer([:positive]),
        vin: "VIN#{System.unique_integer([:positive])}"
      })

    %{admin: admin, member: member, other_member: other_member, car: car}
  end

  test "registration normalizes email and stores only a password hash" do
    email = "  Person-#{System.unique_integer([:positive])}@Example.COM  "

    assert {:ok, user} =
             Accounts.register_user(%{
               email: email,
               name: "注册用户",
               password: @valid_password,
               password_confirmation: @valid_password
             })

    assert user.email == email |> String.trim() |> String.downcase()
    refute user.password_hash == @valid_password
    assert String.starts_with?(user.password_hash, "$pbkdf2-sha256$")
    assert {:ok, authenticated} = Accounts.authenticate_user(user.email, @valid_password)
    assert authenticated.id == user.id
  end

  test "session tokens are stored hashed and disabled users lose access", %{
    admin: admin,
    member: member
  } do
    assert {:ok, raw_token} = Accounts.create_session(member)
    refute Repo.get_by(UserSession, token_hash: raw_token)
    assert Repo.get_by(UserSession, token_hash: :crypto.hash(:sha256, raw_token))
    assert Accounts.get_user_by_session_token(raw_token).id == member.id

    assert {:ok, disabled} =
             Accounts.update_user_access(admin, member, %{status: :disabled, role: :member})

    assert disabled.status == :disabled
    assert Accounts.get_user_by_session_token(raw_token) == nil
  end

  test "members cannot see cars before authorization and admins see all cars", %{
    admin: admin,
    member: member,
    car: car
  } do
    assert Accounts.list_accessible_cars(member) == []
    assert Enum.map(Accounts.list_accessible_cars(admin), & &1.id) == [car.id]

    assert {:ok, _binding} = Accounts.grant_car(admin, member, car.id)
    assert Enum.map(Accounts.list_accessible_cars(member), & &1.id) == [car.id]

    assert Enum.map(Repo.preload(member, :cars).cars, & &1.id) == [car.id]

    binding = Repo.get_by!(Accounts.UserCar, user_id: member.id, car_id: car.id)
    assert Repo.preload(binding, :car).car.id == car.id

    event =
      Enum.find(Accounts.list_audit_events(admin), &(&1.action == "vehicle_access_granted"))

    assert event.car.id == car.id
    assert event.actor_user.id == admin.id
    assert event.target_user.id == member.id
  end

  test "one-time claims are hashed, bind the intended car and cannot be reused", %{
    admin: admin,
    member: member,
    other_member: other_member,
    car: car
  } do
    assert {:ok, claim, raw_code} = Accounts.create_vehicle_claim(admin, car.id, hours: 1)
    refute Repo.get_by(VehicleClaim, token_hash: raw_code)
    assert Repo.get_by(VehicleClaim, token_hash: :crypto.hash(:sha256, raw_code)).id == claim.id

    assert {:ok, _binding} = Accounts.redeem_vehicle_claim(member, raw_code)
    assert Accounts.can_access_car?(member, car.id)
    refute Accounts.can_access_car?(other_member, car.id)

    [loaded_claim] = Accounts.list_vehicle_claims(admin)
    assert loaded_claim.car.id == car.id
    assert loaded_claim.created_by_user.id == admin.id
    assert loaded_claim.claimed_by_user.id == member.id

    assert {:error, :invalid_or_expired_claim} =
             Accounts.redeem_vehicle_claim(other_member, raw_code)
  end

  test "a member cannot enumerate another user's drive", %{
    admin: admin,
    member: member,
    other_member: other_member,
    car: car
  } do
    assert {:ok, _binding} = Accounts.grant_car(admin, member, car.id)
    assert {:ok, drive} = Log.start_drive(car)

    assert Fleet.trip(member, drive.id).drive.id == drive.id
    assert Fleet.trip(other_member, drive.id) == nil
  end

  test "the final active administrator cannot be disabled", %{admin: admin} do
    assert {:error, :system_admin_protected} =
             Accounts.update_user_access(admin, admin, %{status: :disabled, role: :admin})

    assert Accounts.get_user!(admin.id).status == :active
  end

  test "a forged administrator struct cannot retain privileges", %{
    member: member,
    other_member: target,
    car: car
  } do
    stale_admin = %{member | role: :admin, is_system_admin: true}
    assert Accounts.list_users(stale_admin) == []
    assert Accounts.list_accessible_cars(stale_admin) == []
    assert {:error, :forbidden} = Accounts.grant_car(stale_admin, target, car.id)
    assert {:error, :forbidden} = Accounts.create_vehicle_claim(stale_admin, car.id)
  end

  defp unique_email(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}@example.com"
  end
end
