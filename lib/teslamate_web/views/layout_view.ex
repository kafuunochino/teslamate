defmodule TeslaMateWeb.LayoutView do
  use TeslaMateWeb, :view

  import Phoenix.Component
  use PhoenixHTMLHelpers

  def theme_controls(assigns) do
    ~H"""
    <div class="theme-controls" role="group" aria-label="页面颜色模式">
      <button
        type="button"
        class="theme-toggle"
        data-theme-toggle
        aria-label="深色模式"
        aria-pressed="false"
        title="切换颜色模式"
      >
        <i class="mdi mdi-white-balance-sunny" data-theme-icon aria-hidden="true"></i>
        <span data-theme-label>颜色模式</span>
      </button>
      <button
        type="button"
        class="theme-system"
        data-theme-system
        aria-label="恢复跟随系统"
        title="恢复跟随系统"
        hidden
      >
        <i class="mdi mdi-theme-light-dark" aria-hidden="true"></i>
        <span>跟随系统</span>
      </button>
    </div>
    """
  end

  def nav_class(conn, "/") do
    if conn.request_path == "/", do: "is-active", else: nil
  end

  def nav_class(conn, prefix) do
    if String.starts_with?(conn.request_path, prefix), do: "is-active", else: nil
  end
end
