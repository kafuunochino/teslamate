defmodule TeslaMateWeb.TeslaFleetView do
  use TeslaMateWeb, :view
  import TeslaMateWeb.PlatformComponents

  def result_message(result) do
    config = result["configuration"] || result["response"] || result
    skipped = config["skipped_vehicles"] || result["skipped_vehicles"]
    cond do
      not is_nil(skipped) and skipped not in [%{}, []] ->
        "部分车辆未接受配置，请先检查数据钥匙、车辆软件版本和第三方连接数量。"
      config["synced"] == true -> "车辆已同步遥测配置。"
      config["synced"] == false -> "配置已保存，等待车辆上线并同步。"
      config["key_paired"] == false -> "车辆尚未确认数据钥匙，请在 Tesla App 完成配对。"
      true -> "Tesla 已返回结果，请检查同步状态，并等待车辆上报第一条数据。"
    end
  end
end
