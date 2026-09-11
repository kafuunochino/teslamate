defmodule TeslaMate.AccountLifecycleTest do
  use TeslaMate.DataCase, async: false
  alias TeslaMate.{Accounts, Locations, Log, Repo}
  alias TeslaMate.Accounts.{Authenticator, DeletionWorker, Lifecycle, Security, UserSession}
  alias TeslaMate.TeslaFleet.Connection
  @password "correct horse battery staple 42"

  setup do
    start_supervised!(TeslaMate.Vault)
    admin = register("first")
    user = register("member")
    other = register("other")
    {:ok, token} = Accounts.create_session(user)
    {:ok, admin_token} = Accounts.create_session(admin)
    %{admin: admin, user: user, other: other, token: token, admin_token: admin_token}
  end

  defp register(prefix, email \\ nil) do
    {:ok, user} =
      Accounts.register_user(%{
        email: email || "#{prefix}-#{System.unique_integer([:positive])}@example.com",
        name: "Account #{prefix}",
        password: @password,
        password_confirmation: @password,
        role: "admin",
        is_system_admin: true
      })

    user
  end

  defp confirmation(user, extra \\ %{}) do
    Map.merge(
      %{
        "email" => user.email,
        "password" => @password,
        "acknowledge" => "true"
      },
      extra
    )
  end

  defp expire(user) do
    user
    |> Ecto.Changeset.change(
      deletion_requested_at: DateTime.add(DateTime.utc_now(), -8, :day),
      deletion_scheduled_at: DateTime.add(DateTime.utc_now(), -1)
    )
    |> Repo.update!()
  end

  defp factor(user) do
    Repo.insert!(%Authenticator{
      user_id: user.id,
      secret: NimbleTOTP.secret(),
      enabled_at: DateTime.utc_now(),
      recovery_hashes: Enum.map(["request-code", "login-code"], &:crypto.hash(:sha256, &1))
    })
  end

  test "only the first account becomes administrator; signup cannot choose privileges", context do
    assert context.admin.is_system_admin
    assert context.admin.role == :admin
    refute context.user.is_system_admin
    assert context.user.role == :member
    assert context.other.role == :member

    assert {:error, :role_locked} =
             Accounts.update_user_access(context.admin, context.user, %{role: :admin})

    assert {:error, :system_admin_exists} =
             Accounts.bootstrap_admin(%{email: context.other.email})

    assert Accounts.authorized_admin?(context.admin)
    refute Accounts.authorized_admin?(%{context.user | role: :admin, is_system_admin: true})
  end

  test "the primary account cannot be disabled, demoted, deleted or closed", c do
    assert {:error, :system_admin_protected} =
             Accounts.update_user_access(c.admin, c.admin, %{status: :disabled})

    assert {:error, :role_locked} =
             Accounts.update_user_access(c.admin, c.admin, %{role: :member})

    assert {:error, :system_admin_protected} =
             Lifecycle.delete_account(c.admin, c.admin_token, c.admin.id, confirmation(c.admin))

    assert {:error, :system_admin_protected} =
             Lifecycle.request_deletion(c.admin, c.admin_token, confirmation(c.admin))

    assert Accounts.get_user_by_session_token(c.admin_token)
  end

  test "database constraints also reject primary deletion and privilege escalation", c do
    statements = [
      {"DELETE FROM private.users WHERE id = $1", c.admin.id},
      {"UPDATE private.users SET status = 'disabled' WHERE id = $1", c.admin.id},
      {"UPDATE private.users SET role = 'admin' WHERE id = $1", c.user.id},
      {"UPDATE private.users SET is_system_admin = true WHERE id = $1", c.user.id},
      {"UPDATE private.users SET is_system_admin = false, role = 'member' WHERE id = $1",
       c.admin.id}
    ]

    for {sql, id} <- statements do
      Repo.query!("SAVEPOINT admin_invariant")
      assert_raise Postgrex.Error, fn -> Repo.query!(sql, [id]) end
      Repo.query!("ROLLBACK TO SAVEPOINT admin_invariant")
      Repo.query!("RELEASE SAVEPOINT admin_invariant")
    end

    assert Accounts.get_user!(c.admin.id).is_system_admin
  end

  test "confirmation and password are required and failed verification stays rate limited", c do
    assert {:error, :invalid_confirmation} =
             Lifecycle.request_deletion(c.user, c.token, confirmation(c.other))

    assert {:error, :invalid_confirmation} =
             Lifecycle.request_deletion(
               c.user,
               c.token,
               confirmation(c.user, %{"acknowledge" => "false"})
             )

    for _ <- 1..5 do
      assert {:error, :invalid_verification} =
               Lifecycle.request_deletion(
                 c.user,
                 c.token,
                 confirmation(c.user, %{"password" => "wrong"})
               )
    end

    assert Repo.get!(Authenticator, c.user.id).failed_attempts == 5

    assert {:error, :rate_limited} =
             Lifecycle.request_deletion(c.user, c.token, confirmation(c.user))

    refute Accounts.get_user!(c.user.id).deletion_scheduled_at
  end

  test "request stores seven days and revokes every session, challenge and OAuth state", c do
    {:ok, another} = Accounts.create_session(c.user)
    oauth(c.token)
    assert {:ok, scheduled} = Lifecycle.request_deletion(c.user, c.token, confirmation(c.user))

    assert DateTime.diff(scheduled.deletion_scheduled_at, scheduled.deletion_requested_at) ==
             604_800

    refute Accounts.get_user_by_session_token(c.token)
    refute Accounts.get_user_by_session_token(another)
    refute Repo.exists?(from s in UserSession, where: s.user_id == ^c.user.id)
    assert Repo.one(from s in "fleet_oauth_states", prefix: "private", select: count()) == 0
    assert {:error, :account_disabled} = Accounts.create_session(scheduled)

    assert {:error, :forbidden} =
             Lifecycle.request_deletion(c.user, c.token, confirmation(c.user))

    assert :ok = Lifecycle.purge_expired()
    assert Accounts.get_user(c.user.id)
  end

  test "only a successful login cancels the unexpired request", c do
    {:ok, scheduled} = Lifecycle.request_deletion(c.user, c.token, confirmation(c.user))
    assert {:error, :invalid_credentials} = Accounts.authenticate_user(c.user.email, "wrong")
    assert Accounts.get_user!(c.user.id).deletion_scheduled_at
    assert {:ok, verified} = Accounts.authenticate_user(c.user.email, @password)
    assert verified.deletion_scheduled_at == scheduled.deletion_scheduled_at
    assert {:ok, token} = Accounts.create_login_session(verified, %{})
    assert Accounts.get_user_by_session_token(token)
    refute Accounts.get_user!(c.user.id).deletion_scheduled_at
    refute Accounts.get_user!(c.user.id).deletion_requested_at
    refute Accounts.get_user_by_session_token(c.token)
  end

  test "2FA must complete before login cancels deletion", c do
    factor(c.user)

    {:ok, _} =
      Lifecycle.request_deletion(
        c.user,
        c.token,
        confirmation(c.user, %{"code" => "request-code"})
      )

    {:ok, verified} = Accounts.authenticate_user(c.user.email, @password)
    {:ok, challenge} = Security.create_challenge(verified)
    assert Accounts.get_user!(c.user.id).deletion_scheduled_at
    assert {:error, :invalid_verification} = Security.complete_challenge(challenge, "bad-code")
    assert Accounts.get_user!(c.user.id).deletion_scheduled_at
    assert {:ok, _, token} = Security.complete_challenge(challenge, "login-code")
    refute Accounts.get_user!(c.user.id).deletion_scheduled_at
    assert Accounts.get_user_by_session_token(token)
  end

  test "deadline blocks login even when the worker has not run", c do
    factor(c.user)

    {:ok, _} =
      Lifecycle.request_deletion(
        c.user,
        c.token,
        confirmation(c.user, %{"code" => "request-code"})
      )

    {:ok, verified} = Accounts.authenticate_user(c.user.email, @password)
    {:ok, challenge} = Security.create_challenge(verified)
    expire(Accounts.get_user!(c.user.id))
    assert {:error, :invalid_credentials} = Accounts.authenticate_user(c.user.email, @password)
    assert {:error, :account_disabled} = Accounts.create_login_session(verified, %{})
    assert {:error, :invalid_challenge} = Security.complete_challenge(challenge, "login-code")
    assert Accounts.get_user(c.user.id)
    assert :ok = Lifecycle.purge_expired()
    refute Accounts.get_user(c.user.id)
  end

  test "startup sweep catches deadlines missed while the application was stopped", c do
    expire(c.user)
    start_supervised!({DeletionWorker, interval: 60_000})
    assert eventually(fn -> is_nil(Accounts.get_user(c.user.id)) end)
    assert Accounts.get_user(c.admin.id)
    assert Accounts.get_user(c.other.id)
    assert :ok = Lifecycle.purge_expired()
  end

  test "admin deletion requires current session, correct target and both configured factors", c do
    {:ok, other_token} = Accounts.create_session(c.other)

    assert {:error, :forbidden} =
             Lifecycle.delete_account(c.other, other_token, c.user.id, confirmation(c.user))

    assert {:error, :invalid_confirmation} =
             Lifecycle.delete_account(c.admin, c.admin_token, c.user.id, confirmation(c.other))

    assert {:error, :invalid_verification} =
             Lifecycle.delete_account(
               c.admin,
               c.admin_token,
               c.user.id,
               confirmation(c.user, %{"password" => "wrong"})
             )

    # The preceding failed check created the authenticator row.
    Repo.delete_all(from a in Authenticator, where: a.user_id == ^c.admin.id)
    factor(c.admin)

    assert {:error, :invalid_verification} =
             Lifecycle.delete_account(c.admin, c.admin_token, c.user.id, confirmation(c.user))

    assert Accounts.get_user(c.user.id)

    assert {:ok, []} =
             Lifecycle.delete_account(
               c.admin,
               c.admin_token,
               c.user.id,
               confirmation(c.user, %{"code" => "request-code"})
             )

    refute Accounts.get_user(c.user.id)
    assert Accounts.get_user(c.other.id)
  end

  test "deleted accounts lose credentials and bindings while historical records remain admin only",
       c do
    id = System.unique_integer([:positive])
    {:ok, car} = Log.create_car(%{eid: id, vid: id, vin: "ARCHIVE#{id}"})
    {:ok, claim, old_claim} = Accounts.create_vehicle_claim(c.admin, car.id)
    {:ok, _} = Accounts.grant_car(c.admin, c.user, car.id)

    {:ok, fence} =
      Locations.create_geofence(c.user, %{
        name: "Private Home",
        latitude: 30,
        longitude: 100,
        radius: 100
      })

    {:ok, other_fence} =
      Locations.create_geofence(c.other, %{
        name: "Other Home",
        latitude: 31,
        longitude: 101,
        radius: 100
      })

    {:ok, drive} = Log.start_drive(car)

    {:ok, charge} =
      Log.start_charging_process(car, %{date: DateTime.utc_now(), latitude: 30, longitude: 100},
        lookup_address: false
      )

    {:ok, charge} =
      Log.update_charging_process(charge, %{cost: 42.5, charge_energy_added: 10, duration_min: 30})

    Repo.insert!(%Connection{
      authorized_by_id: c.user.id,
      access: "deleted-access",
      refresh: "deleted-refresh",
      expires_at: DateTime.add(DateTime.utc_now(), 3600)
    })

    other_connection =
      Repo.insert!(%Connection{
        authorized_by_id: c.other.id,
        access: "other-access",
        refresh: "other-refresh",
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })

    factor(c.user)
    oauth(c.token)

    assert {:ok, [car_id]} =
             Lifecycle.delete_account(c.admin, c.admin_token, c.user.id, confirmation(c.user))

    assert car_id == car.id
    refute Accounts.get_user(c.user.id)
    refute Repo.get(Authenticator, c.user.id)
    refute Repo.get(Accounts.VehicleClaim, claim.id)
    refute Repo.get(Locations.GeoFence, fence.id)
    assert Repo.get(Locations.GeoFence, other_fence.id)
    assert Repo.get(Connection, other_connection.id).access == "other-access"
    assert Repo.aggregate(Connection, :count) == 1
    assert Repo.get(Log.Drive, drive.id)
    assert Repo.get(Log.ChargingProcess, charge.id).cost == Decimal.new("42.5")
    assert Repo.get(Log.Car, car.id).account_archived_at
    assert Accounts.can_access_car?(c.admin, car.id)
    refute Accounts.can_access_car?(c.other, car.id)
    replacement = register("replacement", c.user.email)
    refute Accounts.can_access_car?(replacement, car.id)

    assert {:error, :invalid_or_expired_claim} =
             Accounts.redeem_vehicle_claim(replacement, old_claim)

    assert {:error, :archived_vehicle} =
             Repo.transaction(fn ->
               locked =
                 Repo.one(from car in Log.Car, where: car.id == ^car_id, lock: "FOR UPDATE")

               Accounts.bind_exclusive!(replacement, locked, replacement.id)
             end)

    assert {:ok, _} = Accounts.grant_car(c.admin, replacement, car.id)
    assert Accounts.can_access_car?(replacement, car.id)
    refute Repo.get(Log.Car, car.id).account_archived_at
  end

  defp oauth(token) do
    Repo.insert_all(
      "fleet_oauth_states",
      [
        %{
          hash: :crypto.strong_rand_bytes(32),
          session_hash: :crypto.hash(:sha256, token),
          expires_at: DateTime.add(DateTime.utc_now(), 300)
        }
      ], prefix: "private")
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
