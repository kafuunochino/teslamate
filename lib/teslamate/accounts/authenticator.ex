defmodule TeslaMate.Accounts.Authenticator do
  use Ecto.Schema
  alias TeslaMate.Vault.Encrypted
  @schema_prefix "private"
  @primary_key {:user_id, :id, autogenerate: false}
  schema "authenticators" do
    field :secret, Encrypted.Binary, redact: true
    field :enabled_at, :utc_datetime_usec
    field :last_used_step, :integer
    field :recovery_hashes, {:array, :binary}, default: [], redact: true
    field :pending_secret, Encrypted.Binary, redact: true
    field :pending_session_hash, :binary, redact: true
    field :pending_expires_at, :utc_datetime_usec
    field :failed_attempts, :integer, default: 0
    field :attempt_window_at, :utc_datetime_usec
  end
end
