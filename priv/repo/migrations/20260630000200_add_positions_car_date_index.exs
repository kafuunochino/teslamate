defmodule TeslaMate.Repo.Migrations.AddPositionsCarDateIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create_if_not_exists(
      index(:positions, [:car_id, :date],
        name: :positions_car_id_date_index,
        concurrently: true
      )
    )
  end
end
