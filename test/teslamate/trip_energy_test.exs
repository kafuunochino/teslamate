defmodule TeslaMate.TripEnergyTest do
  use ExUnit.Case, async: true

  alias TeslaMate.Log.Drive
  alias TeslaMate.TripEnergy

  defp drive do
    %Drive{
      end_date: ~U[2026-09-01 01:00:00Z],
      distance: 20.0,
      start_rated_range_km: Decimal.new("300"),
      end_rated_range_km: Decimal.new("270"),
      start_ideal_range_km: Decimal.new("350"),
      end_ideal_range_km: Decimal.new("340")
    }
  end

  test "uses the selected range with the car coefficient, matching the legacy formula" do
    assert %{energy_kwh: 4.5, consumption_wh_km: 225.0} =
             TripEnergy.calculate(drive(), 0.15, :rated)

    assert %{energy_kwh: 1.5, consumption_wh_km: 75.0} =
             TripEnergy.calculate(drive(), 0.15, :ideal)
  end

  test "retains fractional energy and distance until display formatting" do
    drive = %{
      drive()
      | distance: 2.5,
        start_rated_range_km: Decimal.new("302.13"),
        end_rated_range_km: Decimal.new("300")
    }

    result = TripEnergy.calculate(drive, 0.1319, :rated)
    assert_in_delta result.energy_kwh, 0.280947, 0.000001
    assert_in_delta result.consumption_wh_km, 112.3788, 0.000001
  end

  test "unknown coefficients, missing selected readings and unfinished trips stay unknown" do
    for efficiency <- [nil, 0, -0.1] do
      assert %{energy_kwh: nil, consumption_wh_km: nil} =
               TripEnergy.calculate(drive(), efficiency, :rated)
    end

    for incomplete <- [
          %{drive() | start_rated_range_km: nil},
          %{drive() | end_rated_range_km: nil},
          %{drive() | end_date: nil}
        ] do
      assert %{energy_kwh: nil, consumption_wh_km: nil} =
               TripEnergy.calculate(incomplete, 0.15, :rated)
    end
  end

  test "zero or missing distance does not divide by zero or discard known energy" do
    for distance <- [0, 0.0, nil] do
      assert %{energy_kwh: 4.5, consumption_wh_km: nil} =
               TripEnergy.calculate(%{drive() | distance: distance}, 0.15, :rated)
    end
  end

  test "a measured zero range change remains zero" do
    drive = %{drive() | end_rated_range_km: Decimal.new("300")}

    result = TripEnergy.calculate(drive, 0.15, :rated)
    assert result.energy_kwh == 0.0
    assert result.consumption_wh_km == 0.0
  end

  test "a net range gain is retained instead of clamped to zero" do
    drive = %{drive() | end_rated_range_km: Decimal.new("310")}

    assert %{energy_kwh: -1.5, consumption_wh_km: -75.0} =
             TripEnergy.calculate(drive, 0.15, :rated)
  end
end
