defmodule TeslaMateWeb.UserSettingsView do
  use TeslaMateWeb, :view

  def device_label(nil), do: "已有登录设备"
  def device_label(agent) when is_binary(agent) do
    platform = cond do
      String.contains?(agent, "Tesla") -> "Tesla 车机"
      String.contains?(agent, "Android") -> "Android"
      String.contains?(agent, ["iPhone", "iPad"]) -> "iOS / iPadOS"
      String.contains?(agent, "Windows") -> "Windows"
      String.contains?(agent, "Macintosh") -> "macOS"
      String.contains?(agent, "Linux") -> "Linux"
      true -> "浏览器"
    end
    browser = cond do
      String.contains?(agent, ["Edg/", "EdgA/"]) -> "Edge"
      String.contains?(agent, ["Chrome/", "CriOS/"]) -> "Chrome"
      String.contains?(agent, ["Firefox/", "FxiOS/"]) -> "Firefox"
      String.contains?(agent, "Safari/") -> "Safari"
      true -> "未知浏览器"
    end
    platform <> " · " <> browser
  end
end
