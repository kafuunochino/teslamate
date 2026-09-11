defmodule TeslaMate.TeslaFleet do
  @moduledoc "Official Tesla OAuth connection, isolated from the existing collector credentials."
  import Ecto.Query
  alias TeslaMate.{Accounts, Repo}
  alias TeslaMate.Accounts.{User, UserCar}
  alias TeslaMate.Log.Car
  alias TeslaMate.TeslaFleet.{Client, Config, Connection, Readings}

  # Compatibility for trusted maintenance callers; request handlers must pass a user.
  def connection, do: Repo.one(from c in Connection, order_by: c.id, limit: 1)

  def connection(%User{} = user) do
    if Accounts.active?(user), do: Repo.get_by(Connection, authorized_by_id: user.id)
  end

  def connection(_), do: nil

  def connected_cars(%User{} = user) do
    case connection(user) do
      nil ->
        []

      c ->
        vins = Map.keys(c.vehicles)

        Repo.all(
          from car in Car,
            join: binding in UserCar,
            on: binding.car_id == car.id,
            where: binding.user_id == ^user.id and car.vin in ^vins,
            order_by: car.id
        )
    end
  end

  def start_authorization(session_token) when is_binary(session_token) do
    with user when not is_nil(user) <- Accounts.get_user_by_session_token(session_token),
         true <- Accounts.active?(user),
         {:ok, c} <- Config.get() do
      state = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      now = DateTime.utc_now()

      Repo.delete_all(
        from s in "fleet_oauth_states", prefix: "private", where: s.expires_at < ^now
      )

      Repo.insert_all(
        "fleet_oauth_states",
        [
          %{
            hash: hash(state),
            session_hash: hash(session_token),
            expires_at: DateTime.add(now, 600)
          }
        ],
        prefix: "private"
      )

      url =
        c["auth"] <>
          "/oauth2/v3/authorize?" <>
          URI.encode_query(%{
            "client_id" => c["client_id"],
            "redirect_uri" => c["redirect_uri"],
            "response_type" => "code",
            "scope" => Enum.join(Config.scopes(), " "),
            "state" => state,
            "locale" => "zh-CN",
            "prompt_missing_scopes" => "true",
            "require_requested_scopes" => "true"
          })

      {:ok, url, state}
    else
      _ -> {:error, :not_configured}
    end
  end

  def consume_state(state, expected, session_token)
      when is_binary(state) and is_binary(expected) and is_binary(session_token) do
    with true <- byte_size(state) <= 256 and Plug.Crypto.secure_compare(state, expected),
         user when not is_nil(user) <- Accounts.get_user_by_session_token(session_token),
         true <- Accounts.active?(user) do
      now = DateTime.utc_now()

      {count, _} =
        Repo.delete_all(
          from s in "fleet_oauth_states",
            prefix: "private",
            where:
              s.hash == ^hash(state) and s.session_hash == ^hash(session_token) and
                s.expires_at > ^now
        )

      if count == 1, do: {:ok, user}, else: {:error, :invalid_state}
    else
      _ -> {:error, :invalid_state}
    end
  end

  def consume_state(_, _, _), do: {:error, :invalid_state}

  def connect(code, user, session_token \\ nil)

  def connect(code, user, session_token) when is_binary(code) and byte_size(code) <= 4096 do
    with true <- Accounts.active?(user),
         {:ok, tokens} <- Client.exchange(code),
         {:ok, attrs} <- token_attributes(tokens),
         {:ok, %{"response" => vehicles}} when is_list(vehicles) <-
           Client.request(:get, "/api/1/vehicles", attrs.access) do
      result =
        Repo.transaction(fn ->
          current = Repo.one(from u in User, where: u.id == ^user.id, lock: "FOR UPDATE")

          unless current && current.status == :active && current.auth_version == user.auth_version,
            do: Repo.rollback(:permission_denied)

          if session_token && Accounts.get_user_by_session_token(session_token) == nil,
            do: Repo.rollback(:invalid_state)

          # Serialize VIN insertion and ownership assignment across OAuth callbacks
          # and administrator grants. The unique ownership index is the final guard.
          Repo.query!("SELECT pg_advisory_xact_lock(847300003)")

          vehicles =
            Map.new(Enum.filter(vehicles, &valid_vehicle?/1), fn v ->
              {v["vin"], Map.take(v, ~w(id vehicle_id display_name vin state))}
            end)

          Enum.each(vehicles, fn {vin, vehicle} ->
            car = Repo.one(from car in Car, where: car.vin == ^vin, lock: "FOR UPDATE")
            car = car || insert_vehicle!(vehicle)
            existing = Repo.get_by(UserCar, car_id: car.id)
            binding = Accounts.bind_exclusive!(current, car, current.id)

            if is_nil(existing),
              do: binding |> Ecto.Changeset.change(source: "fleet") |> Repo.update!()
          end)

          vins = Map.keys(vehicles)

          removed =
            Repo.all(
              from b in UserCar,
                join: car in Car,
                on: car.id == b.car_id,
                where: b.user_id == ^current.id and b.source == "fleet" and car.vin not in ^vins,
                select: b.id
            )

          Repo.delete_all(from b in UserCar, where: b.id in ^removed)
          if removed != [], do: Accounts.delete_user_sessions(current)
          # Each account has its own encrypted access and refresh tokens.
          case Repo.get_by(Connection, authorized_by_id: current.id) do
            nil -> %Connection{}
            connection -> connection
          end
          |> Ecto.Changeset.change(
            Map.merge(attrs, %{vehicles: vehicles, authorized_by_id: current.id})
          )
          |> Repo.insert_or_update!()
        end)

      case result do
        {:ok, connection} ->
          if Process.whereis(TeslaMate.Vehicles) do
            Enum.each(connected_cars(user), &TeslaMate.Vehicles.ensure_started/1)
          end

          {:ok, connection}

        error ->
          error
      end
    else
      false -> {:error, :permission_denied}
      {:error, _} = error -> error
      _ -> {:error, :invalid_response}
    end
  end

  def connect(_, _, _), do: {:error, :invalid_response}

  defp insert_vehicle!(%{"id" => eid, "vehicle_id" => vid, "vin" => vin} = vehicle)
       when is_integer(eid) and is_integer(vid) and eid > 0 and vid > 0 do
    %Car{
      fleet_api: true,
      settings: %TeslaMate.Settings.CarSettings{use_streaming_api: false, polling_interval: 30}
    }
    |> Car.changeset(%{eid: eid, vid: vid, vin: vin, name: vehicle["display_name"]})
    |> Repo.insert()
    |> case do
      {:ok, car} -> car
      _ -> Repo.rollback(:invalid_response)
    end
  end

  defp insert_vehicle!(_), do: Repo.rollback(:invalid_response)

  def disconnect(%User{} = user) do
    Repo.transaction(fn ->
      current =
        Repo.one(
          from u in User, where: u.id == ^user.id and u.status == :active, lock: "FOR UPDATE"
        )

      if is_nil(current), do: Repo.rollback(:permission_denied)
      Repo.delete_all(from c in Connection, where: c.authorized_by_id == ^current.id)
      Repo.delete_all(from b in UserCar, where: b.user_id == ^current.id and b.source == "fleet")
      Accounts.delete_user_sessions(current)
      :ok
    end)
  end

  def with_token(fun) when is_function(fun, 1) do
    case connection() do
      %Connection{authorized_by_id: id} when not is_nil(id) ->
        with_token(Accounts.get_user(id), fun)

      _ ->
        {:error, :not_connected}
    end
  end

  def with_token(%User{} = user, fun) when is_function(fun, 1) do
    result =
      Repo.transaction(fn ->
        # Always lock users before connections, matching OAuth and session changes.
        current =
          Repo.one(
            from u in User, where: u.id == ^user.id and u.status == :active, lock: "FOR SHARE"
          )

        if is_nil(current), do: Repo.rollback(:permission_denied)

        case Repo.one(
               from c in Connection, where: c.authorized_by_id == ^current.id, lock: "FOR UPDATE"
             ) do
          nil ->
            Repo.rollback(:not_connected)

          c ->
            if DateTime.diff(c.expires_at, DateTime.utc_now()) > 300 do
              c.access
            else
              with {:ok, tokens} <- Client.refresh(c.refresh),
                   {:ok, attrs} <- token_attributes(tokens, c.scopes),
                   {:ok, c} <- Repo.update(Ecto.Changeset.change(c, attrs)) do
                c.access
              else
                {:error, reason} -> Repo.rollback(reason)
              end
            end
        end
      end)

    case result do
      {:ok, token} when is_binary(token) -> fun.(token)
      {:error, _} = error -> error
      _ -> {:error, :authorization_expired}
    end
  end

  def with_token(_, _), do: {:error, :permission_denied}

  def refresh_if_needed do
    users =
      Repo.all(
        from c in Connection,
          join: u in User,
          on: u.id == c.authorized_by_id,
          where: u.status == :active and c.expires_at < ^DateTime.add(DateTime.utc_now(), 600),
          select: u
      )

    Enum.reduce(users, :ok, fn user, previous ->
      case with_token(user, fn _ -> :ok end) do
        :ok -> previous
        error -> error
      end
    end)
  end

  def check_vehicle(user, vin) do
    with :ok <- known_vehicle(user, vin) do
      with_token(user, fn access ->
        with {:ok, status} <-
               Client.request(:post, "/api/1/vehicles/fleet_status", access, %{"vins" => [vin]}),
             {:ok, config} <-
               Client.request(
                 :get,
                 "/api/1/vehicles/" <> vin <> "/fleet_telemetry_config",
                 access
               ) do
          {:ok,
           %{
             "status" => status["response"] || status,
             "configuration" => config["response"] || config
           }}
        end
      end)
    end
  end

  def configure_vehicle(user, vin, interval) when interval in [5, 10, 30, 60, 300] do
    with :ok <- known_vehicle(user, vin),
         {:ok, c} <- Config.get(),
         host when is_binary(host) and byte_size(host) > 0 <- c["telemetry_host"],
         port when is_integer(port) and port in 1..65535 <- c["telemetry_port"],
         ca when is_binary(ca) <- c["telemetry_ca"],
         true <- String.contains?(ca, "BEGIN CERTIFICATE") do
      config = %{
        "hostname" => host,
        "port" => port,
        "ca" => ca,
        "fields" => Readings.field_config(interval)
      }

      with_token(user, fn access -> Client.configure(vin, access, config) end)
    else
      {:error, _} = error -> error
      _ -> {:error, :receiver_not_configured}
    end
  end

  def known_vehicle(%User{} = user, vin) when is_binary(vin) do
    if Accounts.active?(user) and Regex.match?(~r/^[A-HJ-NPR-Z0-9]{17}$/, vin) do
      case connection(user) do
        %Connection{vehicles: vehicles} ->
          if Map.has_key?(vehicles, vin) and
               Repo.exists?(
                 from car in Car,
                   join: b in UserCar,
                   on: b.car_id == car.id,
                   where: car.vin == ^vin and b.user_id == ^user.id
               ), do: :ok, else: {:error, :unknown_vehicle}

        _ ->
          {:error, :not_connected}
      end
    else
      {:error, :unknown_vehicle}
    end
  end

  def known_vehicle(_, _), do: {:error, :unknown_vehicle}

  # Receiver-only authorization: the VIN must belong to an active account with
  # both an official Tesla grant and the exclusive platform binding.
  def known_vehicle(vin) when is_binary(vin) do
    allowed =
      Repo.exists?(
        from car in Car,
          join: b in UserCar,
          on: b.car_id == car.id,
          join: u in User,
          on: u.id == b.user_id,
          join: c in Connection,
          on: c.authorized_by_id == u.id,
          where:
            car.vin == ^vin and u.status == :active and
              fragment("jsonb_exists(?, ?)", c.vehicles, ^vin)
      )

    if allowed, do: :ok, else: {:error, :unknown_vehicle}
  end

  def known_vehicle(_), do: {:error, :unknown_vehicle}

  def fleet_collector?(id),
    do: Repo.exists?(from car in Car, where: car.eid == ^id and car.fleet_api)

  def collector_vehicle(id, with_state?) do
    owner =
      Repo.one(
        from car in Car,
          join: b in UserCar,
          on: b.car_id == car.id,
          join: u in User,
          on: u.id == b.user_id,
          where: car.eid == ^id and car.fleet_api and u.status == :active,
          select: {u, car.vin}
      )

    with {%User{} = user, vin} <- owner,
         :ok <- known_vehicle(user, vin) do
      path =
        "/api/1/vehicles/" <>
          vin <>
          if(with_state?,
            do:
              "/vehicle_data?endpoints=charge_state%3Bclimate_state%3Bdrive_state%3Bvehicle_config%3Bvehicle_state%3Blocation_data",
            else: ""
          )

      with_token(user, fn access ->
        case Client.request(:get, path, access) do
          {:ok, %{"response" => %{"vin" => ^vin} = vehicle}} ->
            {:ok, TeslaApi.Vehicle.result(vehicle)}

          {:error, :rate_limited} ->
            {:error, :too_many_request, 300}

          {:error, :permission_denied} ->
            {:error, :too_many_request, 900}

          {:error, {:http, 408}} ->
            {:error, :vehicle_unavailable}

          {:error, :authorization_expired} ->
            {:error, :not_signed_in}

          {:error, _} ->
            {:error, :unknown}

          _ ->
            {:error, :unknown}
        end
      end)
    else
      _ -> {:error, :not_signed_in}
    end
  end

  def error_message(:not_configured), do: "尚未配置 Tesla 开发者应用"
  def error_message(:not_connected), do: "请先通过 Tesla 官网授权"
  def error_message(:invalid_state), do: "授权会话已过期或不匹配，请重新发起登录"
  def error_message(:authorization_expired), do: "Tesla 授权已失效，请重新登录 Tesla"
  def error_message(:permission_denied), do: "Tesla 拒绝访问，请检查应用权限、区域或账户额度"
  def error_message(:rate_limited), do: "Tesla 请求频率受限，请稍后重试"
  def error_message(:vehicle_already_bound), do: "车辆已有所属账号。请由管理员核实归属后处理，现有授权未被覆盖"
  def error_message(:unknown_vehicle), do: "该车辆未授权或尚未录入本系统"
  def error_message(:proxy_not_configured), do: "遥测配置服务尚未就绪"
  def error_message(:receiver_not_configured), do: "遥测接收服务尚未配置"
  def error_message(:network_error), do: "无法连接 Tesla 服务，请稍后重试"
  def error_message({:http, status}), do: "Tesla 服务返回 HTTP #{status}，请稍后重试"
  def error_message(_), do: "Tesla 接入未完成，请重新检查授权"

  defp token_attributes(tokens, previous_scopes \\ []) do
    with access when is_binary(access) and byte_size(access) > 0 <- tokens["access_token"],
         refresh when is_binary(refresh) and byte_size(refresh) > 0 <- tokens["refresh_token"],
         expires when is_integer(expires) and expires > 0 and expires <= 31_536_000 <-
           tokens["expires_in"] do
      scopes =
        if is_binary(tokens["scope"]), do: String.split(tokens["scope"]), else: previous_scopes

      {:ok,
       %{
         access: access,
         refresh: refresh,
         expires_at: DateTime.add(DateTime.utc_now(), expires),
         scopes: scopes
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp valid_vehicle?(%{"vin" => vin}) when is_binary(vin),
    do: Regex.match?(~r/^[A-HJ-NPR-Z0-9]{17}$/, vin)

  defp valid_vehicle?(_), do: false
  defp hash(value), do: :crypto.hash(:sha256, value)
end
