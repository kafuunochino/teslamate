defmodule TeslaMateWeb.UserSettingsView do
  use TeslaMateWeb, :view
  import Phoenix.Component, only: [form: 1]

  def authenticator_qr_data_uri(email, key) do
    issuer = "TeslaMate CN"
    label = URI.encode(issuer <> ":" <> email, &URI.char_unreserved?/1)
    query =
      URI.encode_query(
        [secret: key, issuer: issuer, algorithm: "SHA1", digits: 6, period: 30],
        :rfc3986
      )

    image =
      ("otpauth://totp/" <> label <> "?" <> query)
      |> EQRCode.encode(:m)
      |> EQRCode.png(width: 480)
      |> Base.encode64()

    "data:image/png;base64," <> image
  end

  def device_label(nil), do: "已有登录设备"

  def device_label(agent) when is_binary(agent) do
    platform =
      cond do
        String.contains?(agent, "Tesla") -> "Tesla 车机"
        String.contains?(agent, "Android") -> "Android"
        String.contains?(agent, ["iPhone", "iPad"]) -> "iOS / iPadOS"
        String.contains?(agent, "Windows") -> "Windows"
        String.contains?(agent, "Macintosh") -> "macOS"
        String.contains?(agent, "Linux") -> "Linux"
        true -> "浏览器"
      end

    browser =
      cond do
        String.contains?(agent, ["Edg/", "EdgA/"]) -> "Edge"
        String.contains?(agent, ["Chrome/", "CriOS/"]) -> "Chrome"
        String.contains?(agent, ["Firefox/", "FxiOS/"]) -> "Firefox"
        String.contains?(agent, "Safari/") -> "Safari"
        true -> "未知浏览器"
      end

    platform <> " · " <> browser
  end
end
