defmodule TeslaMate.Accounts.UserCar do
  use Ecto.Schema

  @schema_prefix "private"

  schema "user_cars" do
    belongs_to :user, TeslaMate.Accounts.User
    belongs_to :car, TeslaMate.Log.Car
    belongs_to :granted_by_user, TeslaMate.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
