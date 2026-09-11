defmodule TeslaMate.TeslaFleet.Client do
  @moduledoc false
  alias TeslaMate.TeslaFleet.Config

  def exchange(code) do
    with {:ok, c} <- Config.get() do
      token(%{
        "grant_type" => "authorization_code", "client_id" => c["client_id"],
        "client_secret" => c["client_secret"], "code" => code,
        "audience" => c["api"], "redirect_uri" => c["redirect_uri"]
      }, c)
    end
  end

  def refresh(refresh_token) do
    with {:ok, c} <- Config.get() do
      token(%{"grant_type" => "refresh_token", "client_id" => c["client_id"],
        "refresh_token" => refresh_token}, c)
    end
  end

  def request(method, path, access, body \\ nil) do
    with {:ok, c} <- Config.get() do
      send_request(method, c["api"] <> path,
        [{"authorization", "Bearer " <> access}], body && Jason.encode!(body))
    end
  end

  def configure(vin, access, config) do
    with {:ok, c} <- Config.get(),
         proxy when is_binary(proxy) <- c["proxy_url"],
         %URI{scheme: "https", host: host} <- URI.parse(proxy),
         true <- host in ["fleet-proxy", "localhost", "127.0.0.1"] do
      send_request(:post, proxy <> "/api/1/vehicles/fleet_telemetry_config",
        [{"authorization", "Bearer " <> access}],
        Jason.encode!(%{"vins" => [vin], "config" => config}), :proxy)
    else
      _ -> {:error, :proxy_not_configured}
    end
  end

  defp token(params, c) do
    send_request(:post, c["auth"] <> "/oauth2/v3/token",
      [{"content-type", "application/x-www-form-urlencoded"}], URI.encode_query(params))
  end

  # No HTTP logger: OAuth response bodies and request headers contain credentials.
  # Keep errors to status codes; never expose response bodies to HTML or logs.
  defp send_request(method, url, headers, body, pool \\ :public) do
    case Application.get_env(:teslamate, :tesla_fleet_http) do
      fun when is_function(fun, 4) -> fun.(method, url, headers, body)
      _ ->
        headers = [{"accept", "application/json"}, {"user-agent", "ChinoCarData/TeslaMate"} | headers]
        headers = if body && !List.keymember?(headers, "content-type", 0),
          do: [{"content-type", "application/json"} | headers], else: headers
        name = if pool == :proxy, do: TeslaMate.TeslaFleet.ProxyHTTP, else: TeslaMate.HTTP
        with {:ok, response} <- Finch.build(method, url, headers, body) |> Finch.request(name, receive_timeout: 30_000) do
          case response do
            %Finch.Response{status: s, body: b} when s in 200..299 ->
              case Jason.decode(b) do
                {:ok, %{} = data} -> {:ok, data}
                _ -> {:error, :invalid_response}
              end
            %Finch.Response{status: 401} -> {:error, :authorization_expired}
            %Finch.Response{status: 403} -> {:error, :permission_denied}
            %Finch.Response{status: 429} -> {:error, :rate_limited}
            %Finch.Response{status: s} -> {:error, {:http, s}}
          end
        else
          _ -> {:error, :network_error}
        end
    end
  end
end
