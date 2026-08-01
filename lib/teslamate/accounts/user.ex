defmodule TeslaMate.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @schema_prefix "private"

  schema "users" do
    field :email, :string
    field :name, :string
    field :password_hash, :string, redact: true
    field :role, Ecto.Enum, values: [:admin, :member], default: :member
    field :status, Ecto.Enum, values: [:active, :disabled], default: :active
    field :last_login_at, :utc_datetime_usec
    field :password_changed_at, :utc_datetime_usec

    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true

    has_many :sessions, TeslaMate.Accounts.UserSession
    has_many :car_bindings, TeslaMate.Accounts.UserCar
    many_to_many :cars, TeslaMate.Log.Car, join_through: TeslaMate.Accounts.UserCar

    timestamps(type: :utc_datetime_usec)
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :password, :password_confirmation])
    |> normalize_email()
    |> validate_required([:email, :name, :password, :password_confirmation])
    |> validate_length(:email, max: 254)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u)
    |> validate_length(:name, min: 2, max: 80)
    |> validate_password()
    |> unique_constraint(:email, name: :users_email_lower_index)
    |> put_password_hash()
  end

  def bootstrap_admin_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :password, :password_confirmation])
    |> normalize_email()
    |> validate_required([:email, :name, :password, :password_confirmation])
    |> validate_length(:email, max: 254)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u)
    |> validate_length(:name, min: 2, max: 80)
    |> validate_password()
    |> unique_constraint(:email, name: :users_email_lower_index)
    |> put_change(:role, :admin)
    |> put_change(:status, :active)
    |> put_password_hash()
  end

  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 80)
  end

  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_required([:password, :password_confirmation])
    |> validate_password()
    |> put_password_hash()
  end

  def admin_changeset(user, attrs) do
    user
    |> cast(attrs, [:role, :status])
    |> validate_required([:role, :status])
  end

  defp normalize_email(changeset) do
    update_change(changeset, :email, &(&1 |> String.trim() |> String.downcase()))
  end

  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: 12, max: 128)
    |> validate_confirmation(:password, required: true)
  end

  defp put_password_hash(%Ecto.Changeset{valid?: true} = changeset) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    changeset
    |> put_change(
      :password_hash,
      TeslaMate.Accounts.Password.hash(get_change(changeset, :password))
    )
    |> put_change(:password_changed_at, now)
  end

  defp put_password_hash(changeset), do: changeset
end
