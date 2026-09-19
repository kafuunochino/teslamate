defmodule TeslaMate.Accounts.Invitations do
  @moduledoc "Single-use registration invitations. Raw codes are returned only at creation."
  import Ecto.Query
  alias TeslaMate.{Accounts, Repo}
  alias TeslaMate.Accounts.Invitation
  @page_size 20

  def generate(actor, quantity) when is_integer(quantity) and quantity in 1..100 do
    Repo.transaction(fn ->
      policy_lock()
      unless Accounts.authorized_admin?(actor), do: Repo.rollback(:forbidden)

      for _ <- 1..quantity do
        code = "TYH-" <> Base.encode32(:crypto.strong_rand_bytes(16), padding: false)
        label = String.slice(code, 0, 8) <> "…" <> String.slice(code, -4, 4)

        Repo.insert!(%Invitation{
          code_hash: hash(code),
          label: label,
          created_by_id: actor.id
        })

        code
      end
    end)
  end

  def generate(_, _), do: {:error, :invalid_quantity}

  def list(actor, page \\ 1) do
    if Accounts.authorized_admin?(actor) do
      total = Repo.aggregate(Invitation, :count)
      used = Repo.aggregate(from(i in Invitation, where: not is_nil(i.used_at)), :count)
      revoked = Repo.aggregate(from(i in Invitation, where: not is_nil(i.revoked_at)), :count)
      pages = max(1, ceil(total / @page_size))
      page = if is_integer(page), do: min(max(page, 1), pages), else: 1

      entries =
        Repo.all(
          from i in Invitation,
            order_by: [desc: i.id],
            limit: @page_size,
            offset: ^((page - 1) * @page_size),
            select: %{
              id: i.id,
              label: i.label,
              inserted_at: i.inserted_at,
              used_at: i.used_at,
              revoked_at: i.revoked_at
            }
        )

      %{
        entries: entries,
        total: total,
        used: used,
        revoked: revoked,
        available: total - used - revoked,
        page: page,
        pages: pages
      }
    else
      {:error, :forbidden}
    end
  end

  def revoke(actor, id) do
    Repo.transaction(fn ->
      policy_lock()
      unless Accounts.authorized_admin?(actor), do: Repo.rollback(:forbidden)

      {count, _} =
        Repo.update_all(
          from(i in Invitation,
            where: i.id == ^id and is_nil(i.used_at) and is_nil(i.revoked_at)
          ),
          set: [revoked_at: DateTime.utc_now()]
        )

      if count != 1, do: Repo.rollback(:unavailable)
      :ok
    end)
  end

  # Called only inside register_public_user's transaction, after the shared
  # policy lock. Failed account validation rolls back consumption as well.
  def consume(code, user_id) do
    {count, _} =
      Repo.update_all(
        from(i in Invitation,
          where:
            i.code_hash == ^hash(normalize(code)) and is_nil(i.used_at) and is_nil(i.revoked_at)
        ),
        set: [used_at: DateTime.utc_now(), used_by_id: user_id]
      )

    if count == 1, do: :ok, else: {:error, :invalid_invitation}
  end

  def valid?(code) when is_binary(code) and byte_size(code) <= 64 do
    Repo.exists?(
      from i in Invitation,
        where:
          i.code_hash == ^hash(normalize(code)) and is_nil(i.used_at) and is_nil(i.revoked_at)
    )
  end

  def valid?(_), do: false
  defp normalize(code), do: code |> String.trim() |> String.upcase()
  defp hash(code), do: :crypto.hash(:sha256, code)
  defp policy_lock, do: Repo.query!("SELECT pg_advisory_xact_lock(847300002)")
end
