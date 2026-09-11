defmodule TeslaMate.Accounts do
  @moduledoc """
  Platform accounts, revocable sessions and exclusive vehicle ownership.
  Ordinary users can access only their bound vehicles. Global administration
  is separately checked against the current database role.
  """

  import Ecto.Query, warn: false

  alias TeslaMate.Accounts.{AuditEvent, Password, User, UserCar, UserSession, VehicleClaim}
  alias TeslaMate.Log.Car
  alias TeslaMate.Repo

  @session_bytes 32
  @claim_bytes 24
  @default_claim_hours 24
  @max_claim_hours 72

  ## Registration and authentication

  def change_registration(attrs \\ %{}), do: User.registration_changeset(%User{}, attrs)

  def register_user(attrs) when is_map(attrs) do
    changeset = User.registration_changeset(%User{}, attrs)

    Repo.transaction(fn ->
      case Repo.insert(changeset) do
        {:ok, user} ->
          audit(:user_registered, user, target_user: user)
          user

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def authenticate_user(email, password) when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)

    cond do
      is_nil(user) ->
        Password.no_user_verify(password)
        {:error, :invalid_credentials}

      not Password.verify(password, user.password_hash) ->
        {:error, :invalid_credentials}

      user.status != :active ->
        {:error, :invalid_credentials}

      true ->
        now = now()

        {1, _} =
          Repo.update_all(from(u in User, where: u.id == ^user.id), set: [last_login_at: now])

        user = %{user | last_login_at: now}
        audit(:user_logged_in, user, target_user: user)
        {:ok, user}
    end
  end

  def authenticate_user(_, _) do
    Password.no_user_verify("")
    {:error, :invalid_credentials}
  end

  def get_user(id), do: Repo.get(User, parse_id(id))
  def get_user!(id), do: Repo.get!(User, parse_id(id))

  def get_user_by_email(email) when is_binary(email) do
    normalized = normalize_email(email)
    Repo.one(from u in User, where: fragment("lower(?)", u.email) == ^normalized)
  end

  def get_user_by_email(_), do: nil

  def list_users(%User{} = actor) do
    if active_admin_actor?(actor) do
      users = User |> order_by([u], asc: u.inserted_at, asc: u.id) |> Repo.all()

      bindings =
        UserCar
        |> select([uc], {uc.user_id, uc.car_id})
        |> Repo.all()

      cars_by_id =
        bindings
        |> Enum.map(&elem(&1, 1))
        |> case do
          [] -> []
          ids -> Repo.all(from c in Car, where: c.id in ^ids)
        end
        |> Map.new(&{&1.id, &1})

      cars_by_user =
        bindings
        |> Enum.group_by(&elem(&1, 0), fn {_user_id, car_id} -> cars_by_id[car_id] end)
        |> Map.new(fn {user_id, cars} -> {user_id, Enum.reject(cars, &is_nil/1)} end)

      Enum.map(users, &Map.put(&1, :cars, Map.get(cars_by_user, &1.id, [])))
    else
      []
    end
  end

  def list_users(_), do: []

  def admin?(%User{role: :admin, status: :active}), do: true
  def admin?(_), do: false

  @doc "Rechecks an administrator against the database for a privilege boundary."
  def authorized_admin?(%User{} = user), do: active_admin_actor?(user)
  def authorized_admin?(_), do: false

  def sign_up_allowed? do
    Repo.one(from s in "account_settings", prefix: "private",
      where: s.id == 1, select: s.allow_registration) == true
  end

  def set_registration(%User{} = actor, allowed) when is_boolean(allowed) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(847300002)")
      unless active_admin_actor?(actor), do: Repo.rollback(:forbidden)
      {1, _} = Repo.update_all(
        from(s in "account_settings", prefix: "private", where: s.id == 1),
        set: [allow_registration: allowed])
      audit(:registration_policy_changed, actor, metadata: %{"allowed" => allowed})
      allowed
    end)
  end

  def set_registration(_, _), do: {:error, :forbidden}

  def register_public_user(attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(847300002)")
      unless sign_up_allowed?(), do: Repo.rollback(:registration_closed)
      case register_user(attrs) do
        {:ok, user} -> user
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  def active?(%User{id: id}), do: active_user_id?(id)
  def active?(_), do: false

  ## Sessions

  def create_session(user, metadata \\ %{})

  def create_session(%User{} = user, metadata) do
    Repo.transaction(fn ->
      current = Repo.one(from u in User, where: u.id == ^user.id, lock: "FOR UPDATE")
      if is_nil(current) or current.status != :active or current.auth_version != user.auth_version,
        do: Repo.rollback(:account_disabled)

      token = @session_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      time = now()
      session = %UserSession{
        user_id: current.id, token_hash: token_hash(token),
        expires_at: DateTime.add(time, session_days(), :day), last_seen_at: time,
        auth_version: current.auth_version,
        user_agent: bounded_text(metadata[:user_agent], 512),
        ip_address: bounded_text(metadata[:ip_address], 64)
      }
      Repo.insert!(session)
      token
    end)
  end

  def create_session(_, _), do: {:error, :account_disabled}

  def get_user_by_session_token(token) when is_binary(token) and byte_size(token) <= 128 do
    time = now()
    Repo.one(from s in UserSession,
      join: u in assoc(s, :user),
      where: s.token_hash == ^token_hash(token) and s.expires_at > ^time and
        u.status == :active and s.auth_version == u.auth_version,
      select: u, lock: "FOR SHARE")
  end

  def get_user_by_session_token(_), do: nil

  def session_topic(hash) when is_binary(hash),
    do: "platform_session:" <> Base.url_encode64(hash, padding: false)

  def live_socket_id(token), do: token |> token_hash() |> session_topic()

  def touch_session(token) when is_binary(token) do
    time = now()
    cutoff = DateTime.add(time, -60)
    Repo.update_all(from(s in UserSession,
      where: s.token_hash == ^token_hash(token) and s.last_seen_at < ^cutoff and s.expires_at > ^time),
      set: [last_seen_at: time])
    :ok
  end
  def touch_session(_), do: :ok

  def list_sessions(%User{} = user, current_token) do
    if active?(user) do
      hash = if is_binary(current_token), do: token_hash(current_token)
      Repo.all(from s in UserSession, where: s.user_id == ^user.id and s.expires_at > ^now(),
        order_by: [desc: s.last_seen_at],
        select: %{id: s.id, inserted_at: s.inserted_at, last_seen_at: s.last_seen_at,
          expires_at: s.expires_at, user_agent: s.user_agent, ip_address: s.ip_address,
          token_hash: s.token_hash})
      |> Enum.map(fn row -> row |> Map.put(:current?, row.token_hash == hash) |> Map.delete(:token_hash) end)
    else
      []
    end
  end

  def revoke_session(%User{} = actor, id) do
    if active?(actor) do
      query = from s in UserSession, where: s.user_id == ^actor.id and s.id == ^parse_id(id)
      case remove_sessions(query) do
        0 -> {:error, :not_found}
        _ -> :ok
      end
    else
      {:error, :forbidden}
    end
  end

  def revoke_other_sessions(%User{} = actor, current_token) when is_binary(current_token) do
    if not match?(%User{id: id} when id == actor.id, get_user_by_session_token(current_token)) do
      {:error, :forbidden}
    else
      hash = token_hash(current_token)
      remove_sessions(from s in UserSession, where: s.user_id == ^actor.id and s.token_hash != ^hash)
      :ok
    end
  end

  def delete_session(token) when is_binary(token) do
    remove_sessions(from s in UserSession, where: s.token_hash == ^token_hash(token))
    :ok
  end
  def delete_session(_), do: :ok

  def delete_user_sessions(%User{id: id}) do
    remove_sessions(from s in UserSession, where: s.user_id == ^id)
    :ok
  end

  def prune_expired_sessions,
    do: remove_sessions(from s in UserSession, where: s.expires_at <= ^now())

  defp remove_sessions(query) do
    {count, hashes} = Repo.delete_all(select(query, [s], s.token_hash))
    if Process.whereis(TeslaMate.PubSub), do: Enum.each(hashes, &TeslaMateWeb.Endpoint.broadcast(session_topic(&1), "disconnect", %{}))
    count
  end

  defp bounded_text(value, limit) when is_binary(value), do: String.slice(value, 0, limit)
  defp bounded_text(_, _), do: nil

  ## Profiles and administration

  def update_profile(%User{} = user, attrs) do
    with %User{status: :active} = current <- get_user(user.id) do
      current |> User.profile_changeset(attrs) |> Repo.update()
    else
      _ -> {:error, :forbidden}
    end
  end

  def update_password(%User{} = user, current_password, attrs) when is_binary(current_password) do
    Repo.transaction(fn ->
      current = Repo.one!(from u in User, where: u.id == ^user.id, lock: "FOR UPDATE")
      unless current.status == :active and current.auth_version == user.auth_version and Password.verify(current_password, current.password_hash),
        do: Repo.rollback(:invalid_password)
      changeset = current |> User.password_changeset(attrs)
        |> Ecto.Changeset.put_change(:auth_version, current.auth_version + 1)
      case Repo.update(changeset) do
        {:ok, updated_user} ->
          delete_user_sessions(updated_user)
          audit(:password_changed, updated_user, target_user: updated_user)
          updated_user
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def bootstrap_admin(attrs) when is_map(attrs) do
    normalized_email = attrs |> Map.get(:email, Map.get(attrs, "email", "")) |> normalize_email()
    existing = get_user_by_email(normalized_email)
    changeset = User.bootstrap_admin_changeset(existing || %User{}, attrs)
      |> Ecto.Changeset.put_change(:auth_version, if(existing, do: existing.auth_version + 1, else: 1))

    Repo.transaction(fn ->
      case Repo.insert_or_update(changeset) do
        {:ok, user} ->
          delete_user_sessions(user)
          audit(:administrator_bootstrapped, user, target_user: user)
          user

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def update_user_access(%User{} = actor, %User{} = target, attrs) do
    Repo.transaction(fn ->
      # Serialise role/status changes so two concurrent requests cannot both
      # demote what each observed as the last active administrator.
      Repo.query!("SELECT pg_advisory_xact_lock(847300001)")
      unless active_admin_actor?(actor), do: Repo.rollback(:forbidden)

      locked_target = Repo.one!(from u in User, where: u.id == ^target.id, lock: "FOR UPDATE")
      changeset = locked_target |> User.admin_changeset(attrs)
        |> Ecto.Changeset.put_change(:auth_version, locked_target.auth_version + 1)

      if removes_last_active_admin?(locked_target, changeset) do
        Repo.rollback(:last_active_admin)
      end

      case Repo.update(changeset) do
        {:ok, updated_user} ->
          # Roles and account status are authorization inputs. Requiring a
          # fresh login prevents an old cookie from retaining stale rights.
          delete_user_sessions(updated_user)

          audit(:user_access_updated, actor,
            target_user: updated_user,
            metadata: %{
              "role" => Atom.to_string(updated_user.role),
              "status" => Atom.to_string(updated_user.status)
            }
          )

          updated_user

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def update_user_access(_, _, _), do: {:error, :forbidden}

  ## Car authorization

  def scope_cars(user), do: scope_cars(Car, user)

  def scope_cars(query, user)

  def scope_cars(query, %User{id: user_id, status: :active}) do
    if active_admin_id?(user_id) do
      query
    else
      from c in query,
        join: uc in UserCar,
        on: uc.car_id == c.id,
        join: u in User,
        on: u.id == uc.user_id,
        where: uc.user_id == ^user_id and u.status == :active
    end
  end

  def scope_cars(query, _), do: from(c in query, where: false)

  def list_accessible_cars(%User{} = user) do
    Car
    |> scope_cars(user)
    |> order_by([c], asc: c.display_priority, asc: c.id)
    |> Repo.all()
  end

  def get_accessible_car(%User{} = user, id) do
    Car
    |> scope_cars(user)
    |> where([c], c.id == ^parse_id(id))
    |> Repo.one()
  end

  def get_accessible_car(_, _), do: nil

  def can_access_car?(%User{} = user, car_or_id) do
    id = if match?(%Car{}, car_or_id), do: car_or_id.id, else: car_or_id
    not is_nil(get_accessible_car(user, id))
  end

  def grant_car(%User{} = actor, %User{} = target, car_id) do
    Repo.transaction(fn ->
      unless active_admin_actor?(actor), do: Repo.rollback(:forbidden)
      target = Repo.one(from u in User, where: u.id == ^target.id and u.status == :active, lock: "FOR UPDATE")
      if is_nil(target), do: Repo.rollback(:forbidden)
      car = Repo.one(from c in Car, where: c.id == ^parse_id(car_id), lock: "FOR UPDATE")
      if is_nil(car), do: Repo.rollback(:car_not_found)
      binding = bind_exclusive!(target, car, actor.id)
      audit(:vehicle_access_granted, actor, target_user: target, car: car)
      binding
    end)
  end

  @doc false
  def bind_exclusive!(%User{} = user, %Car{} = car, granted_by_id) do
    # Call within a transaction while holding the car row lock.
    case Repo.get_by(UserCar, car_id: car.id) do
      nil ->
        binding = Repo.insert!(%UserCar{user_id: user.id, car_id: car.id, granted_by_user_id: granted_by_id})
        :ok = TeslaMate.Locations.refresh_car_geofences(car.id)
        binding
      %UserCar{user_id: id} = binding when id == user.id -> binding
      _ -> Repo.rollback(:vehicle_already_bound)
    end
  end

  def grant_car(_, _, _), do: {:error, :forbidden}

  def revoke_car(%User{} = actor, %User{} = target, car_id) do
    if active_admin_actor?(actor) do
      id = parse_id(car_id)

      {count, _} =
        Repo.delete_all(from uc in UserCar, where: uc.user_id == ^target.id and uc.car_id == ^id)

      if count > 0 do
        audit(:vehicle_access_revoked, actor, target_user: target, car_id: id)
      end

      :ok
    else
      {:error, :forbidden}
    end
  end

  def revoke_car(_, _, _), do: {:error, :forbidden}

  def unbind_own_car(%User{} = user, car_id) do
    if active_user_id?(user.id) do
      id = parse_id(car_id)

      {count, _} =
        Repo.delete_all(from uc in UserCar, where: uc.user_id == ^user.id and uc.car_id == ^id)

      if count > 0 do
        audit(:vehicle_access_relinquished, user, target_user: user, car_id: id)
      end

      :ok
    else
      {:error, :forbidden}
    end
  end

  ## One-time vehicle claims

  def create_vehicle_claim(actor, car_id, opts \\ [])

  def create_vehicle_claim(%User{} = actor, car_id, opts) do
    hours = opts |> Keyword.get(:hours, @default_claim_hours) |> clamp(1, @max_claim_hours)

    with true <- active_admin_actor?(actor),
         %Car{} = car <- Repo.get(Car, parse_id(car_id)) do
      raw_token = @claim_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      claim = %VehicleClaim{
        car_id: car.id,
        created_by_user_id: actor.id,
        token_hash: token_hash(raw_token),
        expires_at: DateTime.add(now(), hours, :hour)
      }

      case Repo.insert(claim) do
        {:ok, claim} ->
          audit(:vehicle_claim_created, actor,
            car: car,
            metadata: %{"expires_at" => DateTime.to_iso8601(claim.expires_at)}
          )

          {:ok, claim, raw_token}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      false -> {:error, :forbidden}
      nil -> {:error, :car_not_found}
    end
  end

  def create_vehicle_claim(_, _, _), do: {:error, :forbidden}

  def redeem_vehicle_claim(%User{} = user, raw_token) when is_binary(raw_token) do
    hash = raw_token |> String.trim() |> token_hash()
    current_time = now()

    Repo.transaction(fn ->
      active_user =
        Repo.one(
          from u in User,
            where: u.id == ^user.id and u.status == :active,
            lock: "FOR UPDATE"
        )

      if is_nil(active_user), do: Repo.rollback(:invalid_or_expired_claim)

      claim =
        Repo.one(
          from c in VehicleClaim,
            where:
              c.token_hash == ^hash and is_nil(c.claimed_at) and is_nil(c.revoked_at) and
                c.expires_at > ^current_time,
            lock: "FOR UPDATE"
        )

      if is_nil(claim), do: Repo.rollback(:invalid_or_expired_claim)

      car = Repo.one!(from c in Car, where: c.id == ^claim.car_id, lock: "FOR UPDATE")
      binding =
        case Repo.get_by(UserCar, car_id: car.id) do
          nil -> bind_exclusive!(user, car, claim.created_by_user_id)
          %UserCar{user_id: id} = binding when id == user.id -> binding
          _ -> Repo.rollback(:invalid_or_expired_claim)
        end

      {1, _} =
        Repo.update_all(from(c in VehicleClaim, where: c.id == ^claim.id),
          set: [claimed_at: current_time, claimed_by_user_id: user.id, updated_at: current_time]
        )

      audit(:vehicle_claim_redeemed, user,
        target_user: user,
        car_id: claim.car_id,
        metadata: %{"claim_id" => claim.id}
      )

      binding
    end)
  end

  def redeem_vehicle_claim(_, _), do: {:error, :invalid_or_expired_claim}

  def list_vehicle_claims(%User{} = actor) do
    if active_admin_actor?(actor) do
      VehicleClaim
      |> order_by([c], desc: c.inserted_at)
      |> limit(100)
      |> preload([:car, :created_by_user, :claimed_by_user])
      |> Repo.all()
    else
      []
    end
  end

  def list_vehicle_claims(_), do: []

  def revoke_vehicle_claim(%User{} = actor, claim_id) do
    current_time = now()

    if active_admin_actor?(actor) do
      case Repo.transaction(fn ->
             claim =
               Repo.one(
                 from c in VehicleClaim,
                   where: c.id == ^parse_id(claim_id),
                   lock: "FOR UPDATE"
               )

             case claim do
               %VehicleClaim{claimed_at: claimed_at} when not is_nil(claimed_at) ->
                 Repo.rollback(:already_claimed)

               %VehicleClaim{revoked_at: revoked_at} when not is_nil(revoked_at) ->
                 Repo.rollback(:already_revoked)

               %VehicleClaim{} = claim ->
                 {1, _} =
                   Repo.update_all(from(c in VehicleClaim, where: c.id == ^claim.id),
                     set: [revoked_at: current_time, updated_at: current_time]
                   )

                 audit(:vehicle_claim_revoked, actor, car_id: claim.car_id)
                 :ok

               nil ->
                 Repo.rollback(:not_found)
             end
           end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :forbidden}
    end
  end

  def revoke_vehicle_claim(_, _), do: {:error, :forbidden}

  ## Audit

  def list_audit_events(actor, limit \\ 100)

  def list_audit_events(%User{} = actor, limit) do
    if active_admin_actor?(actor) do
      AuditEvent
      |> order_by([e], desc: e.inserted_at, desc: e.id)
      |> limit(^min(max(limit, 1), 500))
      |> preload([:actor_user, :target_user, :car])
      |> Repo.all()
    else
      []
    end
  end

  def list_audit_events(_, _), do: []

  defp audit(action, actor, opts) do
    event = %AuditEvent{
      action: Atom.to_string(action),
      actor_user_id: actor && actor.id,
      target_user_id: opts[:target_user] && opts[:target_user].id,
      car_id: opts[:car_id] || (opts[:car] && opts[:car].id),
      metadata: opts[:metadata] || %{}
    }

    Repo.insert!(event)
  end

  defp removes_last_active_admin?(%User{role: :admin, status: :active}, changeset) do
    next_role = Ecto.Changeset.get_field(changeset, :role)
    next_status = Ecto.Changeset.get_field(changeset, :status)

    (next_role != :admin or next_status != :active) and active_admin_count() <= 1
  end

  defp removes_last_active_admin?(_, _), do: false

  defp active_admin_count do
    Repo.one(from u in User, where: u.role == :admin and u.status == :active, select: count(u.id))
  end

  defp active_admin_actor?(%User{id: id}), do: active_admin_id?(id)
  defp active_admin_actor?(_), do: false

  defp active_admin_id?(id) when is_integer(id) do
    Repo.one(
      from u in User,
        where: u.id == ^id and u.role == :admin and u.status == :active,
        select: u.id,
        limit: 1
    ) != nil
  end

  defp active_admin_id?(_), do: false

  defp active_user_id?(id) when is_integer(id) do
    Repo.one(
      from u in User,
        where: u.id == ^id and u.status == :active,
        select: u.id,
        limit: 1
    ) != nil
  end

  defp active_user_id?(_), do: false

  defp session_days do
    TeslaMateWeb.Config.account_session_days()
  end

  defp token_hash(token), do: :crypto.hash(:sha256, token)
  defp normalize_email(email), do: email |> String.trim() |> String.downcase()
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp clamp(value, minimum, maximum), do: value |> max(minimum) |> min(maximum)

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> value
      _ -> -1
    end
  end

  defp parse_id(_), do: -1
end
