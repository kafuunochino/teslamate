defmodule TeslaMateWeb.LayoutView do
  use TeslaMateWeb, :view

  import Phoenix.Component
  use PhoenixHTMLHelpers

  def nav_class(conn, "/") do
    if conn.request_path == "/", do: "is-active", else: nil
  end

  def nav_class(conn, prefix) do
    if String.starts_with?(conn.request_path, prefix), do: "is-active", else: nil
  end
end
