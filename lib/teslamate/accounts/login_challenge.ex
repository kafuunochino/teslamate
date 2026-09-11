defmodule TeslaMate.Accounts.LoginChallenge do
  use Ecto.Schema
  @schema_prefix "private"
  @primary_key {:token_hash, :binary, autogenerate: false, redact: true}
  schema "login_challenges" do
    field :user_id, :id
    field :auth_version, :integer
    field :expires_at, :utc_datetime_usec
    field :attempts, :integer, default: 0
  end
end
