defmodule TeslaMate.Accounts.Lifecycle do
  @moduledoc "Protected administrator identity and verified, data-preserving account deletion."
  import Ecto.Query
  alias TeslaMate.{Accounts, Locations, Repo, Vehicles}
  alias TeslaMate.Accounts.{AuditEvent, LoginChallenge, Security, User, UserCar, UserSession, VehicleClaim}
  alias TeslaMate.Locations.GeoFence
  alias TeslaMate.Log.Car
  alias TeslaMate.TeslaFleet.Connection

  @cooldown_seconds 7 * 24 * 60 * 60

  def request_deletion(%User{} = user, token, params) when is_map(params) do
    transaction(fn ->
      current = lock_user(user.id)

      cond do
        is_nil(current) -> {:error, :not_found}
        current.is_system_admin -> {:error, :system_admin_protected}
        not confirmed?(current, params) -> {:error, :invalid_confirmation}
        true ->
          # Return verification failures normally so the rate-limit counter commits.
          with :ok <- Security.authorize_account_deletion(
                 current, token, params["password"], params["code"]
               ) do
            time = now()
            updated =
              current
              |> Ecto.Changeset.change(
                deletion_requested_at: time,
                deletion_scheduled_at: DateTime.add(time, @cooldown_seconds),
                auth_version: current.auth_version + 1
              )
              |> Repo.update!()

            revoke_identity_sessions(current)
            record("account_deletion_requested", current.id, current.id, %{
              "scheduled_at" => DateTime.to_iso8601(updated.deletion_scheduled_at)
            })
            {:ok, updated}
          end
      end
    end)
  end

  def request_deletion(_, _, _), do: {:error, :forbidden}

  def delete_account(%User{} = actor, token, target_id, params) when is_map(params) do
    result =
      transaction(fn ->
        # Lock the actor first, consistently with security and Tesla authorization.
        actor = lock_user(actor.id)

        with %User{is_system_admin: true, status: :active} <- actor,
             %User{} = target <- lock_user(target_id),
             false <- target.is_system_admin,
             true <- confirmed?(target, params),
             :ok <- Security.authorize_account_deletion(
               actor, token, params["password"], params["code"]
             ) do
          {:ok, delete_locked!(target, actor.id, "administrator")}
        else
          nil -> {:error, :not_found}
          %User{} -> {:error, :forbidden}
          true -> {:error, :system_admin_protected}
          false -> {:error, :invalid_confirmation}
          error -> error
        end
      end)

    stop_deleted_collectors(result)
  end

  def delete_account(_, _, _, _), do: {:error, :forbidden}

  @doc "Deletes expired requests under row locks; safe to retry after process or VPS restart."
  def purge_expired do
    ids =
      Repo.all(
        from u in User,
          where: not u.is_system_admin and u.deletion_scheduled_at <= ^now(),
          order_by: u.deletion_scheduled_at,
          select: u.id,
          limit: 100
      )

    Enum.each(ids, fn id ->
      transaction(fn ->
        user = Repo.one(from u in User, where: u.id == ^id, lock: "FOR UPDATE SKIP LOCKED")

        if user && not user.is_system_admin && Accounts.deletion_due?(user),
          do: {:ok, delete_locked!(user, nil, "cooldown_expired")},
          else: {:ok, []}
      end)
      |> stop_deleted_collectors()
    end)

    # Also finish stopping collectors if an earlier process died after committing deletion.
    Repo.all(from c in Car, where: not is_nil(c.account_archived_at), select: c.id)
    |> Enum.each(&Vehicles.stop_archived/1)

    :ok
  end

  def error_message(:system_admin_protected), do: "系统第一个账号是唯一管理员，不能停用、删除或注销"
  def error_message(:role_locked), do: "管理员身份固定，不能将其他账号设为管理员"
  def error_message(:invalid_confirmation), do: "请准确输入待删除账号的邮箱，并确认已了解数据处理方式"
  def error_message(:invalid_verification), do: "当前密码或验证码无效，动态码不能重复使用"
  def error_message(:rate_limited), do: "验证尝试过多，请 10 分钟后重试"
  def error_message(:not_found), do: "账号不存在或已经删除"
  def error_message(_), do: "登录状态或账号权限已变化，请刷新后重试"

  defp delete_locked!(user, actor_id, reason) do
    cars =
      Repo.all(
        from c in Car,
          join: b in UserCar, on: b.car_id == c.id,
          where: b.user_id == ^user.id,
          select: c,
          order_by: c.id,
          lock: "FOR UPDATE OF c"
      )
    ids = Enum.map(cars, & &1.id)
    time = now()

    Repo.update_all(from(c in Car, where: c.id in ^ids), set: [account_archived_at: time])
    Repo.delete_all(from c in VehicleClaim, where: c.car_id in ^ids and is_nil(c.claimed_at))
    Repo.delete_all(from c in Connection, where: c.authorized_by_id == ^user.id)

    # Remove private fences using the normal reference cleanup; historical trips and costs remain.
    Repo.all(from g in GeoFence, where: g.user_id == ^user.id, order_by: g.id)
    |> Enum.each(fn fence -> {:ok, _} = Locations.delete_geofence(fence) end)

    revoke_identity_sessions(user)
    Repo.delete!(user)
    record("account_deleted", actor_id, nil, %{
      "deleted_user_id" => user.id,
      "reason" => reason,
      "retained_car_ids" => ids
    })
    ids
  end

  defp revoke_identity_sessions(user) do
    hashes = from s in UserSession, where: s.user_id == ^user.id, select: s.token_hash

    Repo.delete_all(
      from s in "fleet_oauth_states",
        prefix: "private",
        where: s.session_hash in subquery(hashes)
    )
    Repo.delete_all(from c in LoginChallenge, where: c.user_id == ^user.id)
    Accounts.delete_user_sessions(user)
  end

  defp confirmed?(user, params) do
    email = params["email"]
    is_binary(email) and String.downcase(String.trim(email)) == String.downcase(user.email) and
      params["acknowledge"] == "true"
  end

  defp lock_user(id), do: Repo.one(from u in User, where: u.id == ^id, lock: "FOR UPDATE")

  defp record(action, actor_id, target_id, metadata) do
    Repo.insert!(%AuditEvent{
      action: action, actor_user_id: actor_id, target_user_id: target_id, metadata: metadata
    })
  end

  defp stop_deleted_collectors({:ok, ids} = result) do
    Enum.each(ids, &Vehicles.stop_archived/1)
    result
  end

  defp stop_deleted_collectors(error), do: error
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
