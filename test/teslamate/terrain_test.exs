defmodule TeslaMate.TerrainTest do
  use TeslaMate.DataCase, async: true

  alias TeslaMate.Terrain

  def start_terrain(name, responses \\ %{}) do
    log_name = :"log_#{name}"
    srtm_name = :"srtm_#{name}"

    {:ok, _pid} = start_supervised({LogMock, name: log_name, pid: self(), last_update: nil})
    {:ok, _pid} = start_supervised({SRTMMock, name: srtm_name, pid: self(), responses: responses})

    opts = [
      name: name,
      timeout: 500,
      deps_log: {LogMock, log_name},
      deps_srtm: {SRTMMock, srtm_name}
    ]

    {:ok, _} = start_supervised({Terrain, opts})
    assert_receive {:get_positions_without_elevation, 0}

    :ok
  end

  describe "with_elevation/2" do
    test "resolves a saved location while retaining its original timestamp" do
      position = %TeslaMate.Log.Position{
        latitude: Decimal.new("30"),
        longitude: Decimal.new("100"),
        date: ~U[2026-09-01 00:00:00.000000Z]
      }

      result = Terrain.with_elevation(position, fn {30.0, 100.0} -> 1234 end)

      assert result.elevation == 1234
      assert result.date == position.date
      assert position.elevation == nil
    end

    test "keeps an existing elevation without querying terrain" do
      position = %TeslaMate.Log.Position{elevation: 900}
      lookup = fn _ -> flunk("unexpected terrain lookup") end
      assert Terrain.with_elevation(position, lookup) == position
    end

    test "preserves missing data when terrain is unavailable or restarting" do
      position = %TeslaMate.Log.Position{
        latitude: Decimal.new("30"),
        longitude: Decimal.new("100")
      }

      assert Terrain.with_elevation(position, fn _ -> nil end) == position
      assert Terrain.with_elevation(position, fn _ -> exit(:noproc) end) == position
    end

    test "does not query terrain without a recorded position and coordinates" do
      lookup = fn _ -> flunk("unexpected terrain lookup") end
      assert Terrain.with_elevation(nil, lookup) == nil
      position = %TeslaMate.Log.Position{}
      assert Terrain.with_elevation(position, lookup) == position
    end
  end

  describe "get_elevation/1" do
    test "return the elevation", %{test: name} do
      :ok = start_terrain(name, %{{0, 0} => fn -> {:ok, 42} end})

      assert 42 == Terrain.get_elevation(name, {0, 0})
      assert_received {SRTM, {:get_elevation, 0, 0, [disk_cache_path: ".srtm_cache"]}}

      refute_receive _
    end

    @tag :capture_log
    test "return nil if an error occurred", %{test: name} do
      :ok = start_terrain(name, %{{0, 0} => fn -> {:error, :kaputt} end})

      assert Terrain.get_elevation(name, {0, 0}) == nil

      TestHelper.eventually(fn ->
        assert_received {SRTM, {:get_elevation, 0, 0, _opts}}
      end)

      refute_receive _
    end

    test "returns nil if the task takes longer than 100ms", %{test: name} do
      :ok =
        start_terrain(name, %{
          {0, 0} => fn ->
            Process.sleep(550)
            {:ok, 42}
          end
        })

      assert Terrain.get_elevation(name, {0, 0}) == nil

      TestHelper.eventually(fn ->
        assert_received {SRTM, {:get_elevation, 0, 0, _opts}}
      end)

      # still blocked
      assert Terrain.get_elevation(name, {0, 0}) == nil

      refute_receive _, 300
    end

    @tag :capture_log
    test "handles long running tasks that return with an error", %{test: name} do
      :ok =
        start_terrain(name, %{
          {1, 1} => fn ->
            Process.sleep(101)
            {:error, :kaputt}
          end
        })

      assert Terrain.get_elevation(name, {1, 1}) == nil

      TestHelper.eventually(fn ->
        assert_received {SRTM, {:get_elevation, 1, 1, _opts}}
      end)

      refute_receive _
    end

    @tag :capture_log
    test "breaks circuit if too many queries fail", %{test: name} do
      :ok =
        start_terrain(name, %{
          {0, 0} => fn -> {:error, :kaputt} end
        })

      assert Terrain.get_elevation(name, {0, 0}) == nil
      assert Terrain.get_elevation(name, {0, 0}) == nil
      assert Terrain.get_elevation(name, {0, 0}) == nil
      assert Terrain.get_elevation(name, {0, 0}) == nil
      assert Terrain.get_elevation(name, {0, 0}) == nil

      # circuit broke after 3 attempts
      assert_receive {SRTM, {:get_elevation, 0, 0, _opts}}, 1_000
      assert_receive {SRTM, {:get_elevation, 0, 0, _opts}}, 1_000
      assert_receive {SRTM, {:get_elevation, 0, 0, _opts}}, 1_000

      refute_receive _
    end
  end
end
