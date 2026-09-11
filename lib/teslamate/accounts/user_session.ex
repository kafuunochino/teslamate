defmodule TeslaMate.Accounts.UserSession do
  use Ecto.Schema

  @schema_prefix "private"

  schema "user_sessions" do
    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :user_agent, :string
    field :ip_address, :string
    field :auth_version, :integer, default: 1

    belongs_to :user, TeslaMate.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
