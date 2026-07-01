defmodule TeslaMateWeb.LayoutView do
  use TeslaMateWeb, :view

  import Phoenix.Component
  use PhoenixHTMLHelpers

  dashboard_categories = ~w(analysis charging driving energy overview system)

  dashboards =
    for category <- dashboard_categories,
        dashboard_path <- Path.wildcard("grafana/dashboards/#{category}/*.json") do
      @external_resource Path.relative_to_cwd(dashboard_path)

      dashboard_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.take(["title", "uid"])
    end

  @dashboards Enum.sort_by(dashboards, & &1["title"])
  defp list_dashboards, do: @dashboards
end
