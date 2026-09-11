defmodule TeslaMate.Repo.Migrations.AccountSecurityAndOwnership do
  use Ecto.Migration

  def up do
    create table(:account_settings, prefix: "private", primary_key: false) do
      add :id, :integer, primary_key: true
      add :allow_registration, :boolean, null: false, default: false
    end

    execute("INSERT INTO private.account_settings (id, allow_registration) VALUES (1, false)")

    alter table(:users, prefix: "private") do
      add :auth_version, :integer, null: false, default: 1
    end

    alter table(:user_sessions, prefix: "private") do
      add :user_agent, :string, size: 512
      add :ip_address, :string, size: 64
      add :auth_version, :integer, null: false, default: 1
    end

    create table(:authenticators, prefix: "private", primary_key: false) do
      add :user_id, references(:users, prefix: "private", on_delete: :delete_all), primary_key: true
      add :secret, :binary
      add :enabled_at, :utc_datetime_usec
      add :last_used_step, :bigint
      add :recovery_hashes, {:array, :binary}, null: false, default: []
      add :pending_secret, :binary
      add :pending_session_hash, :binary
      add :pending_expires_at, :utc_datetime_usec
      add :failed_attempts, :integer, null: false, default: 0
      add :attempt_window_at, :utc_datetime_usec
    end

    create table(:login_challenges, prefix: "private", primary_key: false) do
      add :token_hash, :binary, primary_key: true
      add :user_id, references(:users, prefix: "private", on_delete: :delete_all), null: false
      add :auth_version, :integer, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :attempts, :integer, null: false, default: 0
    end

    create index(:login_challenges, [:user_id], prefix: "private")
    create index(:login_challenges, [:expires_at], prefix: "private")

    alter table(:user_cars, prefix: "private") do
      add :source, :string, null: false, default: "admin"
    end

    alter table(:cars) do
      add :fleet_api, :boolean, null: false, default: false
    end

    # Ownership is exclusive. Fail safely if an older installation has shared
    # bindings; never silently remove access or guess which owner to retain.
    create unique_index(:user_cars, [:car_id], prefix: "private", name: :user_cars_owner_index)

    alter table(:geofences) do
      add :user_id, references(:users, prefix: "private", on_delete: :restrict)
    end

    create index(:geofences, [:user_id])
    execute("""
    UPDATE public.geofences
    SET user_id = (SELECT id FROM private.users WHERE role = 'admin' AND status = 'active' ORDER BY id LIMIT 1)
    WHERE user_id IS NULL
    """)

    # Preserve the existing encrypted connection and associate it with its
    # authorizing account. IDs remain stable and new rows use a sequence.
    execute("CREATE SEQUENCE private.fleet_connections_id_seq")
    execute("ALTER TABLE private.fleet_connections ALTER COLUMN id SET DEFAULT nextval('private.fleet_connections_id_seq')")
    execute("ALTER SEQUENCE private.fleet_connections_id_seq OWNED BY private.fleet_connections.id")
    execute("SELECT setval('private.fleet_connections_id_seq', GREATEST(COALESCE((SELECT MAX(id) FROM private.fleet_connections), 0), 1), EXISTS(SELECT 1 FROM private.fleet_connections))")
    execute("""
    UPDATE private.fleet_connections
    SET authorized_by_id = (SELECT id FROM private.users WHERE role = 'admin' AND status = 'active' ORDER BY id LIMIT 1)
    WHERE authorized_by_id IS NULL
    """)
    create unique_index(:fleet_connections, [:authorized_by_id], prefix: "private")
  end

  def down do
    raise "This migration contains account security and ownership data. Restore a verified backup to roll back."
  end
end
