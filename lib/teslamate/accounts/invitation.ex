defmodule TeslaMate.Accounts.Invitation do
  use Ecto.Schema

  @schema_prefix "private"
  schema "registration_invitations" do
    field :code_hash, :binary, redact: true
    field :label, :string
    field :used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    belongs_to :created_by, TeslaMate.Accounts.User
    belongs_to :used_by, TeslaMate.Accounts.User
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
