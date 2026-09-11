defmodule TeslaMate.AccountSecurityTest do
  use TeslaMate.DataCase, async: false
  alias TeslaMate.{Accounts, Repo}
  alias TeslaMate.Accounts.{Authenticator, Security, User, UserSession}
  @password "correct horse battery staple 42"

  setup do
    start_supervised!(TeslaMate.Vault)
    admin = TeslaMate.AccountFixtures.system_admin()
    user = user("owner")
    other = user("other")

    {:ok, token} =
      Accounts.create_session(user, %{user_agent: "Android Chrome/100", ip_address: "127.0.0.1"})

    %{user: user, other: other, token: token, admin: admin}
  end

  defp user(prefix) do
    {:ok, user} =
      Accounts.register_user(%{
        email: "#{prefix}-#{System.unique_integer([:positive])}@example.com",
        name: "Security Test",
        password: @password,
        password_confirmation: @password
      })

    user
  end

  defp factor(user) do
    secret = NimbleTOTP.secret()

    Repo.insert!(%Authenticator{
      user_id: user.id,
      secret: secret,
      enabled_at: DateTime.utc_now(),
      recovery_hashes: [:crypto.hash(:sha256, "recovery-code")]
    })

    secret
  end

  test "registration defaults closed and only a current administrator can change it", %{
    user: user, admin: admin
  } do
    refute Accounts.sign_up_allowed?()
    assert {:error, :forbidden} = Accounts.set_registration(user, true)
    assert {:error, :registration_closed} = Accounts.register_public_user(%{})
    assert {:ok, true} = Accounts.set_registration(admin, true)
    assert Accounts.sign_up_allowed?()
    forged = %{user | role: :admin, is_system_admin: true}
    assert {:error, :forbidden} = Accounts.set_registration(forged, false)
  end

  test "public signup cannot choose role, status or session version", %{admin: admin} do
    assert {:ok, true} = Accounts.set_registration(admin, true)

    assert {:ok, registered} =
             Accounts.register_public_user(%{
               email: "public@example.com",
               name: "New User",
               password: @password,
               password_confirmation: @password,
               role: "admin",
               status: "disabled",
               auth_version: 99
             })

    assert registered.role == :member
    assert registered.status == :active
    assert registered.auth_version == 1
    assert {:ok, false} = Accounts.set_registration(admin, false)
    assert {:error, :registration_closed} = Accounts.register_public_user(%{})
    assert {:ok, _} = Accounts.authenticate_user(registered.email, @password)
  end

  test "session list excludes other users and never returns token material", %{
    user: user,
    other: other,
    token: token
  } do
    {:ok, other_token} = Accounts.create_session(other)
    [device] = Accounts.list_sessions(user, token)
    assert device.current?
    assert device.user_agent == "Android Chrome/100"
    refute Map.has_key?(device, :token_hash)
    other_session = Repo.get_by!(UserSession, token_hash: :crypto.hash(:sha256, other_token))
    assert {:error, :not_found} = Accounts.revoke_session(user, other_session.id)
    assert Accounts.get_user_by_session_token(other_token).id == other.id
    assert {:error, :forbidden} = Accounts.revoke_other_sessions(user, other_token)
    assert :ok = Accounts.revoke_session(user, device.id)
    refute Accounts.get_user_by_session_token(token)
  end

  test "revoke other devices keeps only the current device", %{user: user, token: token} do
    {:ok, second} = Accounts.create_session(user)
    assert :ok = Accounts.revoke_other_sessions(user, token)
    assert Accounts.get_user_by_session_token(token)
    refute Accounts.get_user_by_session_token(second)
    assert length(Accounts.list_sessions(user, token)) == 1
  end

  test "enrollment needs password, current session and proof from the authenticator", %{
    user: user,
    token: token
  } do
    assert {:error, :invalid_verification} = Security.begin_enrollment(user, token, "wrong")
    assert {:ok, key} = Security.begin_enrollment(user, token, @password)
    {:ok, second} = Accounts.create_session(user)
    assert Security.status(user, second).setup_key == nil
    refute Security.enabled?(user)
    code = key |> Base.decode32!(padding: false) |> NimbleTOTP.verification_code()
    assert {:error, :setup_expired} = Security.enable(user, second, code)
    assert {:ok, codes, renewed} = Security.enable(user, token, code)
    assert length(codes) == 10
    assert length(Enum.uniq(codes)) == 10
    assert Security.enabled?(user)
    refute Accounts.get_user_by_session_token(token)
    refute Accounts.get_user_by_session_token(second)
    assert Accounts.get_user_by_session_token(renewed).id == user.id
    a = Repo.get!(Authenticator, user.id)
    assert a.pending_secret == nil
    assert Enum.all?(codes, fn c -> :crypto.hash(:sha256, c) in a.recovery_hashes end)

    [[encrypted]] =
      Repo.query!("SELECT secret FROM private.authenticators WHERE user_id = $1", [user.id]).rows

    refute encrypted == Base.decode32!(key, padding: false)
    assert Security.status(user, renewed).setup_key == nil
  end

  test "expired enrollment does not enable 2FA", %{user: user, token: token} do
    {:ok, key} = Security.begin_enrollment(user, token, @password)

    Repo.update_all(from(a in Authenticator, where: a.user_id == ^user.id),
      set: [pending_expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    code = key |> Base.decode32!(padding: false) |> NimbleTOTP.verification_code()
    assert {:error, :setup_expired} = Security.enable(user, token, code)
    refute Security.enabled?(user)
  end

  test "TOTP and challenges cannot be replayed", %{user: user} do
    secret = factor(user)
    {:ok, challenge} = Security.create_challenge(user)
    code = NimbleTOTP.verification_code(secret)
    assert {:ok, authenticated, session} = Security.complete_challenge(challenge, code)
    assert authenticated.id == user.id
    assert Accounts.get_user_by_session_token(session)
    assert {:error, :invalid_challenge} = Security.complete_challenge(challenge, code)
    {:ok, another} = Security.create_challenge(user)
    assert {:error, :invalid_verification} = Security.complete_challenge(another, code)
  end

  test "recovery codes are atomically consumed once", %{user: user} do
    factor(user)
    {:ok, first} = Security.create_challenge(user)
    {:ok, second} = Security.create_challenge(user)
    assert {:ok, _, _} = Security.complete_challenge(first, "recovery-code")
    assert {:error, :invalid_verification} = Security.complete_challenge(second, "recovery-code")
    assert Repo.get!(Authenticator, user.id).recovery_hashes == []
  end

  test "five bad attempts exhaust a challenge and throttle the account", %{user: user} do
    factor(user)
    {:ok, challenge} = Security.create_challenge(user)

    for _ <- 1..5,
        do:
          assert(
            {:error, :invalid_verification} = Security.complete_challenge(challenge, "wrong")
          )

    assert {:error, :invalid_challenge} = Security.complete_challenge(challenge, "recovery-code")
    {:ok, fresh} = Security.create_challenge(user)
    assert {:error, :rate_limited} = Security.complete_challenge(fresh, "recovery-code")
  end

  test "password and role changes invalidate pending challenges and stale user structs", %{
    user: user
  } do
    factor(user)
    {:ok, challenge} = Security.create_challenge(user)
    attrs = %{password: @password <> "new", password_confirmation: @password <> "new"}
    assert {:ok, _} = Accounts.update_password(user, @password, attrs)
    assert {:error, :invalid_challenge} = Security.complete_challenge(challenge, "recovery-code")
    assert {:error, :account_disabled} = Accounts.create_session(user)
    assert {:error, :invalid_challenge} = Security.create_challenge(user)
  end

  test "disabled user cannot finish a valid challenge", %{user: user} do
    factor(user)
    {:ok, challenge} = Security.create_challenge(user)
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [status: :disabled])
    assert {:error, :invalid_challenge} = Security.complete_challenge(challenge, "recovery-code")
  end

  test "disabling requires both factors and invalidates old sessions and recovery codes", %{
    user: user,
    token: token
  } do
    factor(user)

    assert {:error, :invalid_verification} =
             Security.disable(user, token, "wrong", "recovery-code")

    assert Security.enabled?(user)
    assert {:ok, [], new_token} = Security.disable(user, token, @password, "recovery-code")
    refute Security.enabled?(user)
    assert Repo.get!(Authenticator, user.id).secret == nil
    assert Repo.get!(Authenticator, user.id).recovery_hashes == []
    refute Accounts.get_user_by_session_token(token)
    assert Accounts.get_user_by_session_token(new_token)
  end

  test "regenerating recovery codes invalidates old codes and other devices", %{
    user: user,
    token: token
  } do
    factor(user)
    {:ok, other_token} = Accounts.create_session(user)

    assert {:ok, codes, new_token} =
             Security.regenerate_recovery_codes(user, token, @password, "recovery-code")

    assert length(codes) == 10
    refute "recovery-code" in codes
    refute Accounts.get_user_by_session_token(other_token)
    assert Accounts.get_user_by_session_token(new_token)
    assert Security.enabled?(user)
  end
end
