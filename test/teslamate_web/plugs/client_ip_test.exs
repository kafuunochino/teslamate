defmodule TeslaMateWeb.Plugs.ClientIPTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias TeslaMateWeb.Plugs.ClientIP

  setup do
    previous = System.get_env("TESLAMATE_TRUSTED_PROXIES")

    on_exit(fn ->
      if previous do
        System.put_env("TESLAMATE_TRUSTED_PROXIES", previous)
      else
        System.delete_env("TESLAMATE_TRUSTED_PROXIES")
      end
    end)
  end

  test "formats the socket IP and ignores forwarded headers by default" do
    System.delete_env("TESLAMATE_TRUSTED_PROXIES")

    conn =
      conn(:get, "/")
      |> put_req_header("x-forwarded-for", "198.51.100.10")
      |> ClientIP.call([])

    assert conn.private.client_ip == "127.0.0.1"
  end

  test "uses a valid forwarded IP from an explicitly trusted proxy" do
    System.put_env("TESLAMATE_TRUSTED_PROXIES", "127.0.0.1")

    conn =
      conn(:get, "/")
      |> put_req_header("x-forwarded-for", "198.51.100.10, 127.0.0.1")
      |> ClientIP.call([])

    assert conn.private.client_ip == "198.51.100.10"
  end

  test "supports IPv4 and IPv6 proxy networks" do
    System.put_env("TESLAMATE_TRUSTED_PROXIES", "127.0.0.0/8,2001:db8::/32")

    ipv4_conn = conn(:get, "/") |> ClientIP.call([])

    ipv6_conn =
      conn(:get, "/")
      |> Map.put(:remote_ip, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "2001:db8:1::42")
      |> ClientIP.call([])

    assert ipv4_conn.private.client_ip == "127.0.0.1"
    assert ipv6_conn.private.client_ip == "2001:db8:1::42"
  end
end
