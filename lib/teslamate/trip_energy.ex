defmodule TeslaMate.TripEnergy do
  @moduledoc """
  Net driving-energy estimates using the same range-loss model as the legacy
  TeslaMate drive dashboard. The coefficient and range type must stay paired.
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

  def source_label(:fleet_battery), do: "官方电池能量差估算"
  def source_label(:range_estimate), do: "续航变化估算"
  def source_label(:power_estimate), do: "功率积分估算"
  def source_label(_), do: "数据不足"

  def source_note(:fleet_battery),
    do: "使用本程起止的官方电池剩余能量；边界相差不超过 30 秒、时间覆盖至少 90%。结果包含能量回收，也可能受电池管理系统校准和温度影响。"

  def source_note(_),
    do: "本程缺少完整的官方电池起止采样，按续航变化与车辆能耗系数估算。负值可能来自回收或续航校准；数据不足显示“—”。"

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
