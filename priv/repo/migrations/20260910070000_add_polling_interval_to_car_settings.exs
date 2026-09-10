defmodule TeslaMate.Repo.Migrations.AddPollingIntervalToCarSettings do
  use Ecto.Migration

  def change do
    alter table(:car_settings) do
      add :polling_interval, :integer, null: false, default: 0
    end

    create constraint(:car_settings, :car_settings_polling_interval_valid,
             check: "polling_interval IN (0, 5, 10, 15, 30, 60, 120, 300)"
           )
  end
end
