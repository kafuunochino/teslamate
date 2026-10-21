defmodule TeslaMate.Auth.Turnstile do
  @moduledoc "Server-side Cloudflare Turnstile validation for platform authentication."
  require Logger

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
    verify(token, ip, action, %{
      "site_key" => Config.turnstile_site_key(),
      "secret_key" => Config.turnstile_secret_key(),
      "hostnames" => Enum.join(Config.turnstile_hostnames(), ",")
    })
  end

  def verify(token, ip, action, config) do
    cond do
      not TeslaMate.Auth.CaptchaSettings.configured?("cloudflare", config) ->
        rejected(:unavailable, :configuration_missing)

      not is_binary(token) ->
        rejected(:invalid, :response_missing_or_malformed)

      byte_size(token) == 0 or byte_size(token) > 2048 ->
        rejected(:invalid, :response_empty_or_oversized)

      true ->
        request(token, ip, action, config)
    end
  end

  def message(:unavailable), do: "人机验证暂时不可用，请稍后刷新重试或联系管理员"

  def message(:challenge_expired),
    do: "上一次提交的验证已过期或已使用，请完成下方的新验证后再次提交。"

  def message(:verification_configuration),
    do: "人机验证配置不匹配，请联系管理员检查验证服务的网站域名及操作配置。"

  def message(_), do: "请完成人机验证后重试；验证过期时请重新验证"

  defp request(token, ip, action, config) do
    client = Application.get_env(:teslamate, :turnstile_http_client, TeslaMate.HTTP)

    body =
      URI.encode_query(%{
        "secret" => config["secret_key"],
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
      {:ok, %{status: 200, body: response}} -> validate_response(response, action, config)
      _ -> rejected(:unavailable, :transport_error)
    end
  rescue
    _ -> rejected(:unavailable, :transport_error)
  catch
    :exit, _ -> rejected(:unavailable, :transport_error)
  end

  defp validate_response(body, action, config) do
    case Jason.decode(body) do
      {:ok, %{"success" => true} = result} ->
        hostname = result["hostname"]

        cond do
          not is_binary(hostname) ->
            rejected(:verification_configuration, :hostname_missing)

          String.downcase(hostname) not in String.split(config["hostnames"], ",") ->
            rejected(:verification_configuration, :hostname_mismatch)

          result["action"] != action ->
            rejected(:verification_configuration, :action_mismatch)

          true ->
            :ok
        end

      {:ok, %{"success" => false, "error-codes" => codes}} when is_list(codes) ->
        cond do
          Enum.any?(codes, &(&1 in ["missing-input-secret", "invalid-input-secret"])) ->
            rejected(:credentials, :secret_rejected)

          "timeout-or-duplicate" in codes ->
            rejected(:challenge_expired, :timeout_or_duplicate)

          "internal-error" in codes ->
            rejected(:unavailable, :upstream_internal_error)

          true ->
            rejected(:invalid, :response_rejected)
        end

      {:ok, _} ->
        rejected(:invalid, :response_rejected)

      _ ->
        rejected(:unavailable, :malformed_reply)
    end
  end

  defp rejected(reason, diagnostic) do
    # Only fixed categories: never log provider payloads, tokens, keys or user data.
    Logger.warning("[captcha] cloudflare verification failed: #{diagnostic}")
    {:error, reason}
  end
end
