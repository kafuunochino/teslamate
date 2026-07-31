defmodule TeslaMate.Accounts.AuditEvent do
  use Ecto.Schema

  @schema_prefix "private"

  schema "audit_events" do
    field :action, :string
    field :metadata, :map, default: %{}

    belongs_to :actor_user, TeslaMate.Accounts.User
    belongs_to :target_user, TeslaMate.Accounts.User
    belongs_to :car, TeslaMate.Log.Car

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
