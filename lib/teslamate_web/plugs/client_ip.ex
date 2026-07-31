defmodule TeslaMateWeb.Plugs.ClientIP do
  @moduledoc """
  Resolves the real client IP and stashes it in `conn.private[:client_ip]`
  (HTTP requests) and the cookie session (LiveView websocket upgrades).

  ## Why a dedicated plug?

  Phoenix LiveView only exposes `peer_data` / `x_headers` through
  `connect_info`, not on every render. We want both code paths — the HTTP
  `/sign_in` POST and the LiveView `handle_event("sign_in")` — to see the
  *same* canonical IP. Centralising the resolution here keeps both paths
  consistent.

  ## IP resolution

    1. If the *socket peer* is one of the trusted proxies
       (see `TESLAMATE_TRUSTED_PROXIES`), use the **first** entry of
       `X-Forwarded-For`.
    2. Otherwise, fall back to the socket's `remote_ip`.

  Operators behind a reverse proxy MUST:

    1. Configure the proxy to send `X-Forwarded-For`.
    2. Strip any incoming `X-Forwarded-For` from the client before adding
       its own (otherwise clients can spoof).
    3. Set `TESLAMATE_TRUSTED_PROXIES` to a comma-separated list of the
       proxy's network interfaces (e.g. `172.18.0.1,10.0.0.5`). CIDR
       notation is supported (e.g. `172.18.0.0/16`).

  When `TESLAMATE_TRUSTED_PROXIES` is unset, the plug trusts no proxy and
  ignores `X-Forwarded-For`.
  """

  import Bitwise
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    resolved = resolve(conn)

    conn
    |> put_private(:client_ip, resolved)
    |> maybe_put_session()
  end

  # ---- resolution --------------------------------------------------------

  defp resolve(conn) do
    peer = conn.remote_ip
    peer_string = format_ip(peer)

    if trusted_proxy?(peer) do
      forwarded_ip(conn) || peer_string
    else
      peer_string
    end
  end

  defp forwarded_ip(conn) do
    with {_, value} when is_binary(value) <-
           List.keyfind(conn.req_headers, "x-forwarded-for", 0),
         first when is_binary(first) <-
           value |> String.split(",") |> List.first() |> String.trim(),
         parsed when is_tuple(parsed) <- parse_ip(first) do
      format_ip(parsed)
    else
      _ -> nil
    end
  end

  defp format_ip(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      chars when is_list(chars) -> List.to_string(chars)
      _ -> "unknown"
    end
  end

  defp format_ip(_), do: "unknown"

  # ---- trusted-proxy matching --------------------------------------------

  defp trusted_proxies do
    case TeslaMateWeb.Config.trusted_proxies() do
      "" ->
        []

      list ->
        list
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.flat_map(&parse_proxy/1)
    end
  end

  defp parse_proxy(entry) do
    case String.split(entry, "/", parts: 2) do
      [ip] ->
        case parse_ip(ip) do
          parsed when is_tuple(parsed) -> [{:address, parsed}]
          _ -> []
        end

      [ip, prefix] ->
        with parsed when is_tuple(parsed) <- parse_ip(ip),
             {prefix, ""} <- Integer.parse(prefix),
             bits when is_integer(bits) <- address_bits(parsed),
             true <- prefix in 0..bits do
          [{:network, parsed, prefix}]
        else
          _ -> []
        end
    end
  end

  defp parse_ip(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, parsed} -> parsed
      _ -> nil
    end
  end

  defp trusted_proxy?(peer) when is_tuple(peer) do
    Enum.any?(trusted_proxies(), fn
      {:address, address} -> peer == address
      {:network, network, prefix} -> cidr_match?(peer, network, prefix)
    end)
  end

  defp trusted_proxy?(_), do: false

  defp cidr_match?(peer, network, prefix) do
    with {peer, bits} <- ip_integer(peer),
         {network, ^bits} <- ip_integer(network),
         true <- prefix in 0..bits do
      mask =
        if prefix == 0 do
          0
        else
          ((1 <<< prefix) - 1) <<< (bits - prefix)
        end

      (peer &&& mask) == (network &&& mask)
    else
      _ -> false
    end
  end

  defp ip_integer(ip) when tuple_size(ip) == 4 do
    {Enum.reduce(Tuple.to_list(ip), 0, fn part, acc -> acc <<< 8 ||| part end), 32}
  end

  defp ip_integer(ip) when tuple_size(ip) == 8 do
    {Enum.reduce(Tuple.to_list(ip), 0, fn part, acc -> acc <<< 16 ||| part end), 128}
  end

  defp ip_integer(_), do: nil

  defp address_bits(ip) when tuple_size(ip) == 4, do: 32
  defp address_bits(ip) when tuple_size(ip) == 8, do: 128
  defp address_bits(_), do: nil

  # ---- session bridge ----------------------------------------------------

  defp maybe_put_session(%Plug.Conn{} = conn) do
    _session = get_session(conn)
    put_session(conn, :client_ip, conn.private[:client_ip])
  rescue
    _ -> conn
  end
end
