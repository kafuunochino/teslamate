defmodule TeslaMate.TeslaFleet.Connection do
  use Ecto.Schema
  alias TeslaMate.Vault.Encrypted

  @schema_prefix "private"
  @primary_key {:id, :integer, autogenerate: false}
  schema "fleet_connections" do
    field :access, Encrypted.Binary, redact: true
    field :refresh, Encrypted.Binary, redact: true
    field :expires_at, :utc_datetime_usec
    field :scopes, {:array, :string}, default: []
    field :vehicles, :map, default: %{}
    field :authorized_by_id, :id
    timestamps(type: :utc_datetime_usec)
  end
end
