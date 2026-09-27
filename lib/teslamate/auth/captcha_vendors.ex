defmodule TeslaMate.Auth.CaptchaVendors do
  @moduledoc "Captcha 2.0 HTTPS adapters. Tickets are single-use and never retried or logged."

  def verify(provider, config, params, ip) do
    token = params["captcha_token"]
    randstr = params["captcha_randstr"]

    cond do
      not token?(token, 32_768) ->
        {:error, :invalid}

      provider == "tencent" and
          (not token?(randstr, 256) or String.starts_with?(token, "trerror_")) ->
        {:error, :invalid}

      true ->
        {url, body, headers} = request(provider, config, token, randstr, ip, DateTime.utc_now())
        client = Application.get_env(:teslamate, :captcha_http_client, TeslaMate.HTTP)

        case client.post(url, body, headers: headers, receive_timeout: 5_000, pool_timeout: 1_000) do
          {:ok, %{status: 200, body: response}} ->
            case Jason.decode(response) do
              {:ok, data} -> result(provider, data)
              _ -> {:error, :unavailable}
            end

          {:ok, %{status: status}} when status in [401, 403] ->
            {:error, :credentials}

          _ ->
            {:error, :unavailable}
        end
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  # Pure request builders also allow deterministic signing regression tests.
  def request("aliyun", config, token, _randstr, _ip, now) do
    host =
      if config["region"] == "sgp",
        do: "captcha.ap-southeast-1.aliyuncs.com",
        else: "captcha.cn-shanghai.aliyuncs.com"

    body = URI.encode_query(%{"CaptchaVerifyParam" => token, "SceneId" => config["scene_id"]})

    headers = [
      {"content-type", "application/x-www-form-urlencoded"},
      {"host", host},
      {"x-acs-action", "VerifyIntelligentCaptcha"},
      {"x-acs-content-sha256", sha256(body)},
      {"x-acs-date", now |> DateTime.truncate(:second) |> DateTime.to_iso8601()},
      {"x-acs-signature-nonce", Ecto.UUID.generate()},
      {"x-acs-version", "2023-03-05"}
    ]

    {"https://" <> host <> "/", body,
     [{"authorization", aliyun_authorization(config, headers, body)} | headers]}
  end

  def request("tencent", config, token, randstr, ip, now) do
    host = "captcha.tencentcloudapi.com"

    body =
      Jason.encode!(%{
        "CaptchaType" => 9,
        "Ticket" => token,
        "UserIp" => ip,
        "Randstr" => randstr,
        "CaptchaAppId" => String.to_integer(config["app_id"]),
        "AppSecretKey" => config["app_secret_key"]
      })

    headers = [
      {"content-type", "application/json; charset=utf-8"},
      {"host", host},
      {"x-tc-action", "DescribeCaptchaResult"},
      {"x-tc-version", "2019-07-22"},
      {"x-tc-timestamp", to_string(DateTime.to_unix(now))}
    ]

    {"https://" <> host <> "/", body,
     [{"authorization", tencent_authorization(config, headers, body, now)} | headers]}
  end

  def aliyun_authorization(config, headers, body) do
    {canonical_headers, signed} = canonical(headers)

    canonical_request =
      Enum.join(["POST", "/", "", canonical_headers, signed, sha256(body)], "\n")

    signature =
      hmac(config["access_key_secret"], "ACS3-HMAC-SHA256\n" <> sha256(canonical_request))
      |> hex()

    "ACS3-HMAC-SHA256 Credential=#{config["access_key_id"]},SignedHeaders=#{signed},Signature=#{signature}"
  end

  def tencent_authorization(config, headers, body, now) do
    selected =
      Enum.filter(headers, fn {key, _} -> key in ["content-type", "host", "x-tc-action"] end)
      |> Enum.map(fn {key, value} -> {key, String.downcase(value)} end)

    {canonical_headers, signed} = canonical(selected)

    canonical_request =
      Enum.join(["POST", "/", "", canonical_headers, signed, sha256(body)], "\n")

    date = now |> DateTime.to_date() |> Date.to_iso8601()
    scope = date <> "/captcha/tc3_request"

    to_sign =
      Enum.join(
        ["TC3-HMAC-SHA256", to_string(DateTime.to_unix(now)), scope, sha256(canonical_request)],
        "\n"
      )

    key = hmac("TC3" <> config["secret_key"], date) |> hmac("captcha") |> hmac("tc3_request")
    signature = hmac(key, to_sign) |> hex()

    "TC3-HMAC-SHA256 Credential=#{config["secret_id"]}/#{scope}, SignedHeaders=#{signed}, Signature=#{signature}"
  end

  defp result("aliyun", %{
         "Success" => true,
         "Code" => "Success",
         "Result" => %{"VerifyResult" => true, "VerifyCode" => "T001"}
       }),
       do: :ok

  defp result("aliyun", %{"Result" => %{"VerifyCode" => "T005"}}), do: {:error, :test_mode}
  defp result("aliyun", %{"Success" => false}), do: {:error, :credentials}
  defp result("tencent", %{"Response" => %{"CaptchaCode" => 1}}), do: :ok
  defp result("tencent", %{"Response" => %{"Error" => _}}), do: {:error, :credentials}
  defp result("tencent", %{"Response" => %{"CaptchaCode" => 100}}), do: {:error, :credentials}
  defp result(_, _), do: {:error, :invalid}

  defp token?(value, max),
    do: is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max

  defp canonical(headers) do
    sorted = Enum.sort(headers)

    {Enum.map_join(sorted, "", fn {key, value} -> key <> ":" <> String.trim(value) <> "\n" end),
     Enum.map_join(sorted, ";", &elem(&1, 0))}
  end

  defp hmac(key, value), do: :crypto.mac(:hmac, :sha256, key, value)
  defp sha256(value), do: :crypto.hash(:sha256, value) |> hex()
  defp hex(value), do: Base.encode16(value, case: :lower)
end
