defmodule TeslaMateWeb.PlatformComponentsTest do
  use ExUnit.Case, async: true

  import TeslaMateWeb.PlatformComponents, only: [date_time: 1]

  test "renders UTC timestamps in Beijing time, including date rollover" do
    assert date_time(~U[2026-09-09 05:50:00Z]) == "2026-09-09 13:50"
    assert date_time(~U[2026-09-09 16:00:00Z]) == "2026-09-10 00:00"
    assert date_time(~U[2026-12-31 16:00:00Z]) == "2027-01-01 00:00"
  end

  test "treats naive database timestamps as UTC" do
    assert date_time(~N[2026-09-09 05:50:00]) == "2026-09-09 13:50"
  end

  test "does not shift an already localized instant twice" do
    localized = DateTime.shift_zone!(~U[2026-09-09 05:50:00Z], "Asia/Shanghai")
    assert date_time(localized) == "2026-09-09 13:50"
    assert date_time(nil) == "—"
  end
end
