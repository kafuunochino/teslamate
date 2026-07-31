defmodule TeslaMate.Repo.Migrations.CreatePlatformAccounts do
  use Ecto.Migration

  def change do
    create table(:users, prefix: "private") do
      add :email, :string, null: false
      add :name, :string, null: false
      add :password_hash, :text, null: false
      add :role, :string, null: false, default: "member"
      add :status, :string, null: false, default: "active"
      add :last_login_at, :utc_datetime_usec
      add :password_changed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      "CREATE UNIQUE INDEX users_email_lower_index ON private.users (lower(email))",
      "DROP INDEX private.users_email_lower_index"
    )

    create constraint(:users, :users_role_check,
             prefix: "private",
             check: "role IN ('admin', 'member')"
           )

    create constraint(:users, :users_status_check,
             prefix: "private",
             check: "status IN ('active', 'disabled')"
           )

    create table(:user_sessions, prefix: "private") do
      add :user_id,
          references(:users, prefix: "private", on_delete: :delete_all),
          null: false

      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:user_sessions, [:token_hash], prefix: "private")
    create index(:user_sessions, [:user_id], prefix: "private")
    create index(:user_sessions, [:expires_at], prefix: "private")

    create table(:user_cars, prefix: "private") do
      add :user_id,
          references(:users, prefix: "private", on_delete: :delete_all),
          null: false

      add :car_id,
          references(:cars, prefix: "public", on_delete: :delete_all),
          null: false

      add :granted_by_user_id,
          references(:users, prefix: "private", on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:user_cars, [:user_id, :car_id], prefix: "private")
    create index(:user_cars, [:car_id], prefix: "private")

    create table(:vehicle_claims, prefix: "private") do
      add :car_id,
          references(:cars, prefix: "public", on_delete: :delete_all),
          null: false

      add :created_by_user_id,
          references(:users, prefix: "private", on_delete: :delete_all),
          null: false

      add :claimed_by_user_id,
          references(:users, prefix: "private", on_delete: :nilify_all)

      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :claimed_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:vehicle_claims, [:token_hash], prefix: "private")
    create index(:vehicle_claims, [:car_id], prefix: "private")
    create index(:vehicle_claims, [:expires_at], prefix: "private")

    create table(:audit_events, prefix: "private") do
      add :actor_user_id,
          references(:users, prefix: "private", on_delete: :nilify_all)

      add :target_user_id,
          references(:users, prefix: "private", on_delete: :nilify_all)

      add :car_id, references(:cars, prefix: "public", on_delete: :nilify_all)
      add :action, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_events, [:actor_user_id], prefix: "private")
    create index(:audit_events, [:target_user_id], prefix: "private")
    create index(:audit_events, [:car_id], prefix: "private")
    create index(:audit_events, [:inserted_at], prefix: "private")
  end
end
