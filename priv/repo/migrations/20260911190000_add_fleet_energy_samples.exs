defmodule TeslaMate.Repo.Migrations.AddFleetEnergySamples do
  use Ecto.Migration

  def change do
    create table(:fleet_energy_samples, primary_key: false) do
      add :car_id, references(:cars, on_delete: :delete_all), primary_key: true
      add :field, :text, primary_key: true
      add :measured_at, :utc_datetime_usec, primary_key: true
      add :value, :float
    end

    # Keep the original timestamp. A retained latest reading is not a new sample.
    execute(
      """
      INSERT INTO fleet_energy_samples (car_id, field, measured_at, value)
      SELECT car_id, field, measured_at, (data->>'value')::double precision
      FROM fleet_readings
      WHERE field IN ('EnergyRemaining', 'Soc', 'NominalFullPackEnergyKwh',
                      'ACChargingEnergyIn', 'DCChargingEnergyIn')
      ON CONFLICT DO NOTHING
      """,
      "SELECT 1"
    )
  end
end
