defmodule TeslaMate.AccountFixtures do
  import Ecto.Query
  alias TeslaMate.{Accounts, Repo}
  alias TeslaMate.Accounts.User

  def system_admin do
    Repo.one(from u in User, where: u.is_system_admin) ||
      Repo.insert!(%User{
        email: "system-admin-#{System.unique_integer([:positive])}@example.com",
        name: "System Admin",
        password_hash: "test-only-not-a-valid-password-hash",
        password_changed_at: DateTime.utc_now()
      })
  end

  def member do
    system_admin()
    Repo.insert!(%User{
      email: "member-#{System.unique_integer([:positive])}@example.com",
      name: "Test Member",
      password_hash: "test-only-not-a-valid-password-hash",
      password_changed_at: DateTime.utc_now()
    })
  end

  def grant(user, car), do: Accounts.grant_car(system_admin(), user, car.id)
  def revoke(user, car), do: Accounts.revoke_car(system_admin(), user, car.id)
end
