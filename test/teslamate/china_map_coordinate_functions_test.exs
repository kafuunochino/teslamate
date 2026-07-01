defmodule TeslaMate.ChinaMapCoordinateFunctionsTest do
  use TeslaMate.DataCase

  test "converts mainland WGS-84 coordinates to GCJ-02 for AMap" do
    %{rows: [[lat, lng]]} =
      Repo.query!("""
      SELECT
        tm_lat_for_map('https://wprd01.is.autonavi.com/', 39.913818, 116.397828),
        tm_lng_for_map('https://wprd01.is.autonavi.com/', 39.913818, 116.397828)
      """)

    assert_in_delta lat, 39.91522, 0.00001
    assert_in_delta lng, 116.40407, 0.00001
  end

  test "keeps WGS-84 coordinates for non-GCJ map sources" do
    %{rows: [[lat, lng]]} =
      Repo.query!("""
      SELECT
        tm_lat_for_map('https://tile.openstreetmap.org/', 39.913818, 116.397828),
        tm_lng_for_map('https://tile.openstreetmap.org/', 39.913818, 116.397828)
      """)

    assert lat == 39.913818
    assert lng == 116.397828
  end

  test "does not offset coordinates outside mainland China" do
    %{rows: [[lat, lng]]} =
      Repo.query!("""
      SELECT
        tm_lat_for_map('https://wprd01.is.autonavi.com/', 52.520008, 13.404954),
        tm_lng_for_map('https://wprd01.is.autonavi.com/', 52.520008, 13.404954)
      """)

    assert lat == 52.520008
    assert lng == 13.404954
  end
end
