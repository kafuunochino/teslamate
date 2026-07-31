defmodule TeslaMateWeb.Plugs.ApiOriginCheckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias TeslaMateWeb.Plugs.ApiOriginCheck

  setup do
    previous = System.get_env("TESLAMATE_API_ORIGIN_CHECK")
    System.put_env("TESLAMATE_API_ORIGIN_CHECK", "true")

    on_exit(fn ->
      if previous do
        System.put_env("TESLAMATE_API_ORIGIN_CHECK", previous)
      else
        System.delete_env("TESLAMATE_API_ORIGIN_CHECK")
      end
    end)
  end

  test "rejects a cross-origin mutation without a referer" do
    conn =
      conn(:post, "/api/car/1/logging/resume")
      |> Map.put(:host, "teslamate.example")
      |> put_req_header("origin", "https://attacker.example")

    log =
      capture_log(fn ->
        conn = ApiOriginCheck.call(conn, [])

        assert conn.halted
        assert conn.status == 403
        assert conn.resp_body == ~s({"error":"forbidden_origin"})
      end)

    assert log =~ "[api-origin] rejected POST /api/car/1/logging/resume"
    assert log =~ "referer="
  end
end
