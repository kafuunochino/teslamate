defmodule TeslaMate.Repo.Migrations.CreateMapSettings do
  use Ecto.Migration

  def change do
    create table(:map_settings, primary_key: false, prefix: "private") do
      add :id, :integer, primary_key: true
      add :provider, :string, null: false, default: "openstreetmap"
      add :amap_key, :binary
      add :amap_security_code, :binary
      timestamps()
    end

    create constraint(:map_settings, :map_settings_singleton, check: "id = 1", prefix: "private")

    create constraint(:map_settings, :map_settings_provider,
             check: "provider IN ('openstreetmap', 'amap')",
             prefix: "private"
           )

    execute(
      "INSERT INTO private.map_settings (id, provider, inserted_at, updated_at) VALUES (1, 'openstreetmap', NOW(), NOW())",
      "DELETE FROM private.map_settings WHERE id = 1"
    )
  end
end
