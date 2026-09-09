defmodule TeslaMate.ChargeCosts do
  @moduledoc """
  Manual charging costs scoped to the current user's accessible vehicles.
  """

  import Ecto.Query
  import Ecto.Changeset

  alias TeslaMate.Accounts
  alias TeslaMate.Accounts.User
  alias TeslaMate.Log.ChargingProcess
  alias TeslaMate.Repo

  def get(%User{} = user, id) when is_integer(id) do
    user |> scoped_query(id) |> Repo.one()
  end

  def change(%ChargingProcess{} = charge, attrs \\ %{}) do
    changeset = cast(charge, attrs, [:cost])

    case get_field(changeset, :cost) do
      %Decimal{coef: coefficient} when is_integer(coefficient) ->
        changeset
        |> validate_number(:cost, greater_than: -10_000, less_than: 10_000)
        |> validate_change(:cost, fn :cost, cost ->
          if Decimal.equal?(cost, Decimal.round(cost, 2)),
            do: [],
            else: [cost: "金额最多保留两位小数"]
        end)

      nil ->
        changeset

      _ ->
        add_error(changeset, :cost, "请输入有效金额")
    end
  end

  def update(%User{} = user, %ChargingProcess{} = previous, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      charge = user |> scoped_query(previous.id) |> lock("FOR UPDATE") |> Repo.one()

      cond do
        is_nil(charge) ->
          Repo.rollback(:forbidden)

        is_nil(charge.end_date) ->
          Repo.rollback(:in_progress)

        not same_cost?(charge.cost, previous.cost) ->
          Repo.rollback(:conflict)

        true ->
          case charge |> change(attrs) |> Repo.update() do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
  end

  defp scoped_query(user, id) do
    cars = user |> Accounts.scope_cars() |> select([car], car.id)

    from charge in ChargingProcess,
      where: charge.id == ^id and charge.car_id in subquery(cars)
  end

  defp same_cost?(nil, nil), do: true
  defp same_cost?(nil, _), do: false
  defp same_cost?(_, nil), do: false
  defp same_cost?(left, right), do: Decimal.equal?(left, right)
end
