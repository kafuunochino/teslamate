defmodule TeslaMate.Repo.Migrations.AddRegistrationInvitations do
  use Ecto.Migration

  def change do
    alter table(:account_settings, prefix: "private") do
      add :require_invitation, :boolean, null: false, default: false
    end

    create table(:registration_invitations, prefix: "private") do
      add :code_hash, :binary, null: false
      add :label, :string, null: false
      add :created_by_id, references(:users, prefix: "private", on_delete: :nilify_all)
      add :used_by_id, references(:users, prefix: "private", on_delete: :nilify_all)
      add :used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:registration_invitations, [:code_hash], prefix: "private")
    create index(:registration_invitations, [:inserted_at], prefix: "private")
  end
end
