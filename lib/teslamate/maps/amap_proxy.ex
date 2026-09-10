defmodule TeslaMate.Maps.AmapProxy do
  @moduledoc false

  alias TeslaMate.Maps.Settings

  # Only the map SDK's read endpoints. No arbitrary upstream URLs, route
  # planners or other paid Web Service APIs can be called through this proxy.
  @rest_paths ~w(v3/log/init v4/log v4/maps v4/map/lite v4/map/config v3/coordinate/convert)
  @style_paths ~w(v4/map/styles v4/map/styles/data v4/map/styles/info)

  def request(
        %Settings{provider: :amap} = settings,
        path,
        query,
        request_fun \\ &TeslaMate.HTTP.get/2
      ) do
    with {:ok, url} <- upstream_url(settings, path, query),
         {:ok, %Finch.Response{status: 200, headers: headers, body: body}} <-
           request_fun.(url,
             receive_timeout: 10_000,
             pool_timeout: 5_000,
             headers: [{"referer", TeslaMateWeb.Endpoint.url() <> "/"}]
           ),
         true <- is_binary(body) and byte_size(body) <= 4_194_304,
         {:ok, content_type, body} <- normalize_response(query, headers, body) do
      # Never reflect the server credential in an upstream diagnostic response.
      body = :binary.replace(body, settings.amap_security_code, "[REDACTED]", [:global])
      {:ok, content_type, body}
    else
      {:error, :invalid_request} -> {:error, :invalid_request}
      _ -> {:error, :upstream_unavailable}
    end
  end

  # AMap can send JSONP as application/json or application/octet-stream.
  # With nosniff enabled browsers correctly reject those as scripts. Only
  # promote the requested callback wrapping valid JSON to JavaScript.
  defp normalize_response(query, headers, body) do
    case URI.decode_query(query)["callback"] do
      callback when is_binary(callback) and callback != "" ->
        prefix = callback <> "("
        payload = String.trim(body) |> String.trim_trailing(";") |> String.trim_trailing()

        with true <- String.starts_with?(payload, prefix) and String.ends_with?(payload, ")"),
             json <-
               binary_part(payload, byte_size(prefix), byte_size(payload) - byte_size(prefix) - 1),
             {:ok, decoded} <- Jason.decode(json) do
          {:ok, "application/javascript; charset=utf-8",
           callback <> "(" <> Jason.encode!(decoded) <> ");"}
        else
          _ -> {:error, :upstream_unavailable}
        end

      _ ->
        content_type =
          Enum.find_value(headers, "application/octet-stream", fn {name, value} ->
            if String.downcase(name) == "content-type", do: value
          end)

        {:ok, content_type, body}
    end
  end

  def upstream_url(%Settings{amap_key: key, amap_security_code: code}, path, query)
      when is_list(path) and is_binary(query) and byte_size(query) <= 16_384 and
             is_binary(key) and is_binary(code) do
    path = Enum.join(path, "/")

    host =
      cond do
        path in @style_paths -> "https://webapi.amap.com/"
        path in @rest_paths -> "https://restapi.amap.com/"
        true -> nil
      end

    params = URI.decode_query(query)
    callback = Map.get(params, "callback", "")

    if host &&
         (callback == "" ||
            Regex.match?(~r/\A[a-zA-Z_$][\w$]*(?:\.[a-zA-Z_$][\w$]*)*\z/, callback)) do
      params = params |> Map.put("key", key) |> Map.put("jscode", code)
      {:ok, host <> path <> "?" <> URI.encode_query(params)}
    else
      {:error, :invalid_request}
    end
  rescue
    ArgumentError -> {:error, :invalid_request}
  end

  def upstream_url(_, _, _), do: {:error, :invalid_request}
end
