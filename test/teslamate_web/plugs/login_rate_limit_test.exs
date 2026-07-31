defmodule TeslaMateWeb.Plugs.LoginRateLimitTest do
  use ExUnit.Case, async: false

  alias TeslaMateWeb.Plugs.LoginRateLimit
  alias TeslaMateWeb.Plugs.LoginRateLimit.TableOwner

  setup do
    LoginRateLimit.ensure_started()
    assert pid = Process.whereis(TableOwner)
    assert Process.alive?(pid)
    :ets.delete_all_objects(:teslamate_login_rate_limits)

    on_exit(fn ->
      :ets.delete_all_objects(:teslamate_login_rate_limits)
    end)
  end

  test "counts failures without a cutoff" do
    assert LoginRateLimit.hit_count(:ip, "127.0.0.1") == 0

    assert :ok = LoginRateLimit.record_failure("127.0.0.1", nil)

    assert LoginRateLimit.hit_count(:ip, "127.0.0.1") == 1
  end
end
