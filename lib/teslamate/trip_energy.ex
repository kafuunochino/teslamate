defmodule TeslaMate.TripEnergy do
  @moduledoc """
  Shared net driving energy, preferring timestamped battery-pack states.
  The legacy range-loss fallback keeps its coefficient and range type paired.
  """

  alias TeslaMate.Log.Drive

  def calculate(drive, efficiency, range, official) do
    case official do
      %{energy_kwh: kwh, source: :fleet_battery} = sample when is_number(kwh) ->
        distance = number(drive.distance)

        Map.put(
          sample,
          :consumption_wh_km,
          if(is_number(distance) and distance > 0, do: kwh * 1000 / distance)
        )

      _ ->
        calculate(drive, efficiency, range)
    end
  end

  def source_label(:fleet_battery), do: "电池包读数计算"
  def source_label(:range_estimate), do: "续航变化估算"
  def source_label(:power_estimate), do: "功率积分估算"
  def source_label(_), do: "数据不足"

  def source_note(:fleet_battery),
    do: "净耗电量 = 起点电池剩余能量 − 终点电池剩余能量；平均能耗 = 净耗电量 ÷ 本程里程。Tesla 按数值变化上报，未变化时沿用当时有效的读数，最长 10 分钟；保留原始采样时间。读数来自电池管理系统，包含回收影响，也可能随温度和校准变化。"

  def source_note(:power_estimate),
    do: "缺少可还原本程起止电池状态的历史采样，按已记录功率积分；超过 30 秒的缺失时段不外推。"

  def source_note(_),
    do: "本程电池历史不足、存在无效读数或状态过期，按续航变化与车辆能耗系数估算。绑定钥匙前未保存的电池读数无法补回；当前剩余能量不会用于重算过去的行程。负值可能来自回收或续航校准。"

  def summary_label(_official, 0), do: "数据不足"
  def summary_label(official, total) when official == total, do: "全部按电池包读数计算"
  def summary_label(0, _total), do: "续航变化估算"
  def summary_label(official, total), do: "#{official} 程电池读数 · #{total - official} 程续航估算"

  def calculate(%Drive{end_date: nil}, _efficiency, _range), do: empty()

  def calculate(%Drive{} = drive, efficiency, range)
      when is_number(efficiency) and efficiency > 0 and range in [:ideal, :rated] do
    {start_range, end_range} =
      case range do
        :ideal -> {drive.start_ideal_range_km, drive.end_ideal_range_km}
        :rated -> {drive.start_rated_range_km, drive.end_rated_range_km}
      end

    with start_value when is_number(start_value) and start_value >= 0 <- number(start_range),
         end_value when is_number(end_value) and end_value >= 0 <- number(end_range) do
      # Preserve a net gain: regeneration or range recalibration can increase
      # the reported range. Missing readings must never become zero energy.
      energy = (start_value - end_value) * efficiency
      distance = number(drive.distance)

      %{
        source: :range_estimate,
        energy_kwh: energy,
        consumption_wh_km: if(is_number(distance) and distance > 0, do: energy * 1000 / distance)
      }
    else
      _ -> empty()
    end
  end

  def calculate(_drive, _efficiency, _range), do: empty()

  defp empty, do: %{energy_kwh: nil, consumption_wh_km: nil, source: :unavailable}
  defp number(%Decimal{} = value), do: Decimal.to_float(value)
  defp number(value) when is_number(value), do: value
  defp number(_), do: nil
end
