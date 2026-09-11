defmodule TeslaMate.TeslaFleet.Config do
  @moduledoc false
  @regions %{
    "cn" => {"https://auth.tesla.cn", "https://fleet-api.prd.cn.vn.cloud.tesla.cn"},
    "na" =>
      {"https://fleet-auth.prd.vn.cloud.tesla.com", "https://fleet-api.prd.na.vn.cloud.tesla.com"},
    "eu" =>
      {"https://fleet-auth.prd.vn.cloud.tesla.com", "https://fleet-api.prd.eu.vn.cloud.tesla.com"}
  }
  @scopes ~w(openid offline_access vehicle_device_data vehicle_location)

  def get do
    case Application.get_env(:teslamate, :tesla_fleet_config) do
      %{} = config -> validate(config)
      _ -> load_file(System.get_env("TESLA_FLEET_CONFIG", ""))
    end
  end

  def configured?, do: match?({:ok, _}, get())
  def scopes, do: @scopes

  defp load_file(""), do: {:error, :not_configured}

  defp load_file(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, config} <- Jason.decode(contents) do
      validate(config)
    else
      _ -> {:error, :not_configured}
    end
  end

  defp validate(config) do
    with id when is_binary(id) and byte_size(id) > 0 <- config["client_id"],
         secret when is_binary(secret) and byte_size(secret) > 0 <- config["client_secret"],
         {auth, api} <- @regions[config["region"]],
         %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path} <-
           URI.parse(config["origin"] || ""),
         true <- is_binary(host) and path in [nil, "", "/"] do
      {:ok,
       Map.merge(config, %{
         "auth" => auth,
         "api" => api,
         "origin" => String.trim_trailing(config["origin"], "/"),
         "redirect_uri" => String.trim_trailing(config["origin"], "/") <> "/auth/tesla/callback"
       })}
    else
      _ -> {:error, :not_configured}
    end
  end
end
