defmodule TeslaMateWeb.TeslaFleetView do
  use TeslaMateWeb, :view
  import Phoenix.Component, only: [form: 1]
  import TeslaMateWeb.PlatformComponents

  def result_message(result) do
    config = result["configuration"] || result["response"] || result
    skipped = config["skipped_vehicles"] || result["skipped_vehicles"]

    cond do
      not is_nil(skipped) and skipped not in [%{}, []] ->
        "部分车辆未接受配置，请先检查数据钥匙、车辆软件版本和第三方连接数量。"

      config["key_paired"] == false or
          (is_list(get_in(result, ["status", "unpaired_vins"])) and
             get_in(result, ["status", "unpaired_vins"]) != []) ->
        "车辆尚未确认数据钥匙，请在 Tesla App 完成配对。"

      config["limit_reached"] == true ->
        "车辆遥测连接数量已达上限，请检查已授权应用。"

      Map.has_key?(config, "config") and is_nil(config["config"]) ->
        "车辆尚未启用电池遥测，请完成钥匙配对后启用。"

      config["synced"] == true ->
        "车辆已同步遥测配置。"

      config["synced"] == false ->
        "配置已保存，等待车辆上线并同步。"

      true ->
        "Tesla 已返回结果，请检查同步状态，并等待车辆上报第一条数据。"
    end
  end

  def vehicle_status(%{"status" => %{"vehicle_info" => vehicles} = status})
      when is_map(vehicles) do
    paired = status["key_paired_vins"] || []

    for {vin, info} <- vehicles, is_map(info) do
      %{
        firmware: info["firmware_version"] || "未知",
        telemetry: info["fleet_telemetry_version"] || "未知",
        keys: info["total_number_of_keys"],
        paired?: is_list(paired) and vin in paired
      }
    end
  end

  def vehicle_status(_), do: []
end
