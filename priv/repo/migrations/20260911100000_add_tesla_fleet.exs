defmodule TeslaMate.Repo.Migrations.AddTeslaFleet do
  use Ecto.Migration

  def change do
    create table(:fleet_connections, prefix: "private", primary_key: false) do
      add :id, :integer, primary_key: true
      add :access, :binary, null: false
      add :refresh, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :vehicles, :map, null: false, default: %{}
      add :authorized_by_id, references(:users, prefix: "private", on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create table(:fleet_oauth_states, prefix: "private", primary_key: false) do
      add :hash, :binary, primary_key: true
      add :session_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    create table(:fleet_readings, primary_key: false) do
      add :car_id, references(:cars, on_delete: :delete_all), primary_key: true
      add :field, :string, primary_key: true
      add :data, :map, null: false
      add :measured_at, :utc_datetime_usec, null: false
      add :received_at, :utc_datetime_usec, null: false
    end
  end
end
