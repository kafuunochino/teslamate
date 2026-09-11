defmodule TeslaMate.TeslaFleet do
  @moduledoc "Official Tesla OAuth connection, isolated from the existing collector credentials."
  import Ecto.Query
  alias TeslaMate.{Accounts, Repo}
  alias TeslaMate.TeslaFleet.{Client, Config, Connection, Readings}

  def connection, do: Repo.get(Connection, 1)

  def start_authorization(session_token) when is_binary(session_token) do
    with user when not is_nil(user) <- Accounts.get_user_by_session_token(session_token),
         true <- Accounts.authorized_admin?(user),
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
         true <- Accounts.authorized_admin?(user) do
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

  def connect(code, user) when is_binary(code) and byte_size(code) <= 4096 do
    with true <- Accounts.authorized_admin?(user),
         {:ok, tokens} <- Client.exchange(code),
         {:ok, attrs} <- token_attributes(tokens),
         {:ok, %{"response" => vehicles}} when is_list(vehicles) <-
           Client.request(:get, "/api/1/vehicles", attrs.access) do
      vehicles =
        Map.new(Enum.filter(vehicles, &valid_vehicle?/1), fn v ->
          {v["vin"], Map.take(v, ~w(id vehicle_id display_name vin state))}
        end)

      attrs = Map.merge(attrs, %{id: 1, vehicles: vehicles, authorized_by_id: user.id})

      %Connection{id: 1}
      |> Ecto.Changeset.change(attrs)
      |> Repo.insert(
        on_conflict: {:replace, Map.keys(Map.delete(attrs, :id)) ++ [:updated_at]},
        conflict_target: [:id]
      )
    else
      false -> {:error, :permission_denied}
      {:error, _} = error -> error
      _ -> {:error, :invalid_response}
    end
  end

  def with_token(fun) when is_function(fun, 1) do
    result =
      Repo.transaction(fn ->
        case Repo.one(from c in Connection, where: c.id == 1, lock: "FOR UPDATE") do
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

  def refresh_if_needed do
    case connection() do
      nil ->
        :ok

      %Connection{expires_at: expiry} ->
        if DateTime.diff(expiry, DateTime.utc_now()) < 600,
          do: with_token(fn _ -> :ok end),
          else: :ok
    end
  end

  def check_vehicle(vin) do
    with :ok <- known_vehicle(vin) do
      with_token(fn access ->
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

  def configure_vehicle(vin, interval) when interval in [5, 10, 30, 60, 300] do
    with :ok <- known_vehicle(vin),
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

      with_token(fn access -> Client.configure(vin, access, config) end)
    else
      {:error, _} = error -> error
      _ -> {:error, :receiver_not_configured}
    end
  end

  def known_vehicle(vin) when is_binary(vin) do
    if Regex.match?(~r/^[A-HJ-NPR-Z0-9]{17}$/, vin) do
      case connection() do
        %Connection{vehicles: vehicles} ->
          if Map.has_key?(vehicles, vin) and
               Repo.exists?(from c in TeslaMate.Log.Car, where: c.vin == ^vin),
             do: :ok,
             else: {:error, :unknown_vehicle}

        _ ->
          {:error, :not_connected}
      end
    else
      {:error, :unknown_vehicle}
    end
  end

  def known_vehicle(_), do: {:error, :unknown_vehicle}

  def error_message(:not_configured), do: "尚未配置 Tesla 开发者应用"
  def error_message(:not_connected), do: "请先通过 Tesla 官网授权"
  def error_message(:invalid_state), do: "授权会话已过期或不匹配，请重新发起登录"
  def error_message(:authorization_expired), do: "Tesla 授权已失效，请重新登录 Tesla"
  def error_message(:permission_denied), do: "Tesla 拒绝访问，请检查应用权限、区域或账户额度"
  def error_message(:rate_limited), do: "Tesla 请求频率受限，请稍后重试"
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
