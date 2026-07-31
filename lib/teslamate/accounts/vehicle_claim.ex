defmodule TeslaMate.Accounts.VehicleClaim do
  use Ecto.Schema

  @schema_prefix "private"

  schema "vehicle_claims" do
    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime_usec
    field :claimed_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :car, TeslaMate.Log.Car
    belongs_to :created_by_user, TeslaMate.Accounts.User
    belongs_to :claimed_by_user, TeslaMate.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end
end
