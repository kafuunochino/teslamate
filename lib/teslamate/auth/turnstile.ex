defmodule TeslaMate.Auth.Turnstile do
  @moduledoc "Server-side Cloudflare Turnstile validation for platform authentication."

  alias TeslaMateWeb.Config
  alias TeslaMateWeb.Plugs.LoginRateLimit

  @endpoint "https://challenges.cloudflare.com/turnstile/v0/siteverify"

  def required?(ip, action, email \\ nil) do
    Config.turnstile_enabled?() and
      (action == "register" or LoginRateLimit.challenge_required?(ip, email))
  end

  def configured? do
    Config.turnstile_site_key() != "" and Config.turnstile_secret_key() != "" and
      Config.turnstile_hostnames() != []
  end

  def verify_if_required(params, ip, action, email \\ nil) do
    if required?(ip, action, email) do
      verify(Map.get(params, "cf-turnstile-response"), ip, action)
    else
      :ok
    end
  end

  def verify(token, ip, action) do
    cond do
      not configured?() -> {:error, :unavailable}
      not is_binary(token) -> {:error, :invalid}
      byte_size(token) == 0 or byte_size(token) > 2048 -> {:error, :invalid}
      true -> request(token, ip, action)
    end
  end

  def message(:unavailable), do: "人机验证暂时不可用，请稍后刷新重试或联系管理员"
  def message(_), do: "请完成人机验证后重试；验证过期时请重新验证"

  defp request(token, ip, action) do
    client = Application.get_env(:teslamate, :turnstile_http_client, TeslaMate.HTTP)

    body =
      URI.encode_query(%{
        "secret" => Config.turnstile_secret_key(),
        "response" => token,
        "remoteip" => ip
      })

    # Never retry the same token: Cloudflare tokens are single-use. Do not log
    # the request, response, or exception, which could contain credentials.
    case client.post(@endpoint, body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}],
           receive_timeout: 5_000,
           pool_timeout: 1_000
         ) do
      {:ok, %{status: 200, body: response}} -> validate_response(response, action)
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp validate_response(body, action) do
    case Jason.decode(body) do
      {:ok, %{"success" => true, "hostname" => hostname, "action" => ^action}}
      when is_binary(hostname) ->
        if String.downcase(hostname) in Config.turnstile_hostnames(),
          do: :ok,
          else: {:error, :invalid}

      {:ok, _} ->
        {:error, :invalid}

      _ ->
        {:error, :unavailable}
    end
  end
end
