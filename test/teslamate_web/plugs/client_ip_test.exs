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

  test "Docker IPv4-mapped peers match IPv4 proxy addresses and networks" do
    for proxy <- ["172.18.0.1", "172.18.0.0/16", "::ffff:172.18.0.1", "::ffff:172.18.0.0/112"],
        peer <- ["172.18.0.1", "::ffff:172.18.0.1"] do
      System.put_env("TESLAMATE_TRUSTED_PROXIES", proxy)

      conn = request(peer, [{"x-forwarded-for", "198.51.100.10"}]) |> ClientIP.call([])
      assert conn.private.client_ip == "198.51.100.10", "proxy=#{proxy}, peer=#{peer}"
    end
  end

  test "IPv4-mapped clients use a single canonical representation" do
    System.delete_env("TESLAMATE_TRUSTED_PROXIES")
    assert ClientIP.resolve(request("::ffff:198.51.100.10")) == "198.51.100.10"

    System.put_env("TESLAMATE_TRUSTED_PROXIES", "172.18.0.1")

    conn = request("172.18.0.1", [{"x-forwarded-for", "::ffff:198.51.100.10"}])
    assert ClientIP.resolve(conn) == "198.51.100.10"
  end

  test "unconfigured or untrusted peers cannot supply forwarding headers" do
    for proxies <- ["", "172.19.0.0/16", "::/0", "invalid,172.18.0.1/33,::1/129"] do
      System.put_env("TESLAMATE_TRUSTED_PROXIES", proxies)

      conn =
        request("::ffff:172.18.0.1", [
          {"x-forwarded-for", "198.51.100.10"},
          {"x-real-ip", "203.0.113.20"}
        ])

      assert ClientIP.resolve(conn) == "172.18.0.1"
    end
  end

  test "CIDR trust does not leak to neighboring networks or unrelated IPv6 addresses" do
    System.put_env("TESLAMATE_TRUSTED_PROXIES", "172.18.0.0/16,2001:db8:1::/48")

    for peer <- ["172.19.0.1", "::ffff:172.19.0.1", "::172.18.0.1", "2001:db8:2::1"] do
      conn = request(peer, [{"x-forwarded-for", "198.51.100.10"}])
      refute ClientIP.resolve(conn) == "198.51.100.10"
    end
  end

  test "appended client addresses take precedence over a forged leftmost address" do
    System.put_env("TESLAMATE_TRUSTED_PROXIES", "172.18.0.1")

    conn = request("::ffff:172.18.0.1", [{"x-forwarded-for", "203.0.113.99, 198.51.100.10"}])
    assert ClientIP.resolve(conn) == "198.51.100.10"
  end

  test "walks all trusted hops in a mixed IPv4 and IPv6 proxy chain" do
    System.put_env("TESLAMATE_TRUSTED_PROXIES", "172.18.0.1,10.0.0.0/24,2001:db8:1::/48")

    conn =
      request("::ffff:172.18.0.1", [
        {"x-forwarded-for", "203.0.113.99, 198.51.100.10, ::ffff:10.0.0.5, 2001:db8:1::5"}
      ])

    assert ClientIP.resolve(conn) == "198.51.100.10"
  end

  test "stops at an untrusted intermediate proxy" do
    System.put_env("TESLAMATE_TRUSTED_PROXIES", "172.18.0.1")
    conn = request("172.18.0.1", [{"x-forwarded-for", "198.51.100.10, 10.0.0.5"}])
    assert ClientIP.resolve(conn) == "10.0.0.5"
  end

  test "multiple forwarded header lines are processed as one ordered chain" do
    System.put_env("TESLAMATE_TRUSTED_PROXIES", "172.18.0.1,10.0.0.5")

    conn =
      request("172.18.0.1", [
        {"x-forwarded-for", "203.0.113.99"},
        {"x-forwarded-for", "198.51.100.10, 10.0.0.5"}
      ])

    assert ClientIP.resolve(conn) == "198.51.100.10"
  end

  test "invalid hops cannot be skipped or replaced with X-Real-IP" do
    System.put_env("TESLAMATE_TRUSTED_PROXIES", "172.18.0.1,10.0.0.5")

    for invalid <- ["", "unknown", "garbage", "127.1", "198.51.100.10:1234", "[2001:db8::1]"] do
      conn =
        request("172.18.0.1", [
          {"x-forwarded-for", "203.0.113.99, #{invalid}, 10.0.0.5"},
          {"x-real-ip", "203.0.113.88"}
        ])

      assert ClientIP.resolve(conn) == "10.0.0.5"
    end
  end

  test "malformed and empty forwarding headers retain the normalized socket address" do
    System.put_env("TESLAMATE_TRUSTED_PROXIES", "172.18.0.1")

    for value <- ["", " ", "invalid", "198.51.100.10,", <<255>>] do
      conn = request("::ffff:172.18.0.1", [{"x-forwarded-for", value}])
      assert ClientIP.resolve(conn) == "172.18.0.1"
    end

    assert ClientIP.resolve(request("::ffff:172.18.0.1")) == "172.18.0.1"
  end

  test "untrusted malformed prefixes do not hide a valid appended client" do
    System.put_env("TESLAMATE_TRUSTED_PROXIES", "172.18.0.1")
    conn = request("172.18.0.1", [{"x-forwarded-for", "unknown, 198.51.100.10"}])
    assert ClientIP.resolve(conn) == "198.51.100.10"
  end

  test "accepts X-Real-IP only as an unambiguous fallback from a trusted peer" do
    System.put_env("TESLAMATE_TRUSTED_PROXIES", "172.18.0.1")

    conn = request("::ffff:172.18.0.1", [{"x-real-ip", " ::ffff:198.51.100.10 "}])
    assert ClientIP.resolve(conn) == "198.51.100.10"

    for headers <- [
          [{"x-real-ip", "invalid"}],
          [{"x-real-ip", <<255>>}],
          [{"x-real-ip", "198.51.100.10, 203.0.113.20"}],
          [{"x-real-ip", "198.51.100.10"}, {"x-real-ip", "203.0.113.20"}]
        ] do
      assert ClientIP.resolve(request("172.18.0.1", headers)) == "172.18.0.1"
    end
  end

  test "X-Forwarded-For always takes precedence over X-Real-IP" do
    System.put_env("TESLAMATE_TRUSTED_PROXIES", "172.18.0.1")

    cases = [{"198.51.100.10", "198.51.100.10"}, {"invalid", "172.18.0.1"}]

    for {forwarded, expected} <- cases do
      conn =
        request("172.18.0.1", [
          {"x-forwarded-for", forwarded},
          {"x-real-ip", "203.0.113.20"}
        ])

      assert ClientIP.resolve(conn) == expected
    end
  end

  test "refreshes the LiveView session bridge using the same canonical IP as HTTP" do
    System.put_env("TESLAMATE_TRUSTED_PROXIES", "172.18.0.1")

    conn =
      request("::ffff:172.18.0.1", [{"x-forwarded-for", "198.51.100.10"}])
      |> init_test_session(%{client_ip: "172.18.0.1"})
      |> ClientIP.call([])

    assert conn.private.client_ip == "198.51.100.10"
    assert get_session(conn, :client_ip) == "198.51.100.10"
  end

  defp request(peer, headers \\ []) do
    {:ok, address} = :inet.parse_strict_address(String.to_charlist(peer))

    conn(:get, "/")
    |> Map.put(:remote_ip, address)
    |> Map.put(:req_headers, headers)
  end
end
