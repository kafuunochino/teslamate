defmodule TeslaMate.TripEnergy do
  @moduledoc """
  Net driving-energy estimates using the same range-loss model as the legacy
  TeslaMate drive dashboard. The coefficient and range type must stay paired.
  """

  alias TeslaMate.Log.Drive

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
        energy_kwh: energy,
        consumption_wh_km: if(is_number(distance) and distance > 0, do: energy * 1000 / distance)
      }
    else
      _ -> empty()
    end
  end

  def calculate(_drive, _efficiency, _range), do: empty()

  defp empty, do: %{energy_kwh: nil, consumption_wh_km: nil}
  defp number(%Decimal{} = value), do: Decimal.to_float(value)
  defp number(value) when is_number(value), do: value
  defp number(_), do: nil
end
