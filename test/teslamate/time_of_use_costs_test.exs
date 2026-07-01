defmodule TeslaMate.TimeOfUseCostsTest do
  use TeslaMate.DataCase

  test "falls back to the original cost when no TOU cost exists" do
    %{rows: [[cost]]} = Repo.query!("SELECT tm_effective_cost(-1, 42.50)")

    assert Decimal.equal?(cost, Decimal.new("42.50"))
  end

  test "matches a global overnight mainland-China rate" do
    Repo.query!("""
    INSERT INTO tm_tou_rates (hour_start, hour_end, rate, label)
    VALUES (22, 8, 0.30, '谷')
    """)

    %{rows: [[rate]]} =
      Repo.query!("SELECT tm_lookup_tou_rate(TIMESTAMP '2026-06-30 15:00:00', NULL, FALSE)")

    assert Decimal.equal?(rate, Decimal.new("0.30"))
  end

  test "requires complete rate coverage instead of silently pricing gaps at zero" do
    Repo.query!("""
    INSERT INTO tm_tou_rates (hour_start, hour_end, rate, label)
    VALUES (22, 23, 0.30, '谷')
    """)

    %{rows: [[rate]]} =
      Repo.query!("SELECT tm_lookup_tou_rate(TIMESTAMP '2026-06-30 16:30:00', NULL, FALSE)")

    assert is_nil(rate)
  end
end
