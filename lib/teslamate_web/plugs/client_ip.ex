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

    1. Normalize IPv4-mapped IPv6 addresses before proxy matching and display.
    2. If the socket peer is trusted (see `TESLAMATE_TRUSTED_PROXIES`), walk
       `X-Forwarded-For` from right to left, stopping at the first untrusted
       address. Multiple header lines form one chain. An invalid hop stops
       resolution; it must never be skipped to reach a spoofed address.
    3. Use a single `X-Real-IP` only when `X-Forwarded-For` is absent and the
       socket peer is trusted. Otherwise, keep the socket's `remote_ip`.

  Operators behind a reverse proxy MUST:

    1. Configure the proxy to send `X-Forwarded-For`.
    2. Overwrite incoming forwarding headers at the public edge, or append
       the actual socket peer to `X-Forwarded-For` at each trusted hop.
       Always overwrite `X-Real-IP` if using that fallback.
    3. Set `TESLAMATE_TRUSTED_PROXIES` to a comma-separated list of the
       proxy's network interfaces (e.g. `172.18.0.1,10.0.0.5`). CIDR
       notation is supported (e.g. `172.18.0.0/16`).

  When `TESLAMATE_TRUSTED_PROXIES` is unset, the plug trusts no proxy and
  ignores all forwarding headers. Run this plug after `:fetch_session`
  when the resolved address must also be available to LiveViews.
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

  @doc "Resolves the canonical client IP, including when called outside the router pipeline."
  def resolve(conn) do
    peer = conn.remote_ip
    proxies = trusted_proxies()

    resolved = if trusted_proxy?(peer, proxies), do: forwarded_ip(conn, peer, proxies), else: peer
    format_ip(resolved)
  end

  defp forwarded_ip(conn, peer, proxies) do
    case get_req_header(conn, "x-forwarded-for") do
      [] ->
        case get_req_header(conn, "x-real-ip") do
          [value] -> parse_ip(value) || peer
          _ -> peer
        end

      headers ->
        headers
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.reverse()
        |> Enum.reduce_while(peer, fn value, current ->
          if trusted_proxy?(current, proxies) do
            case parse_ip(value) do
              nil -> {:halt, current}
              address -> {:cont, address}
            end
          else
            {:halt, current}
          end
        end)
    end
  end

  defp format_ip(ip) when is_tuple(ip) do
    case :inet.ntoa(normalize_ip(ip)) do
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
    with true <- String.valid?(ip),
         {:ok, parsed} <- :inet.parse_strict_address(ip |> String.trim() |> String.to_charlist()) do
      parsed
    else
      _ -> nil
    end
  end

  defp trusted_proxy?(peer, proxies) when is_tuple(peer) do
    Enum.any?(proxies, fn
      {:address, address} -> normalize_ip(peer) == normalize_ip(address)
      {:network, network, prefix} -> cidr_match?(peer, network, prefix)
    end)
  end

  defp trusted_proxy?(_, _), do: false

  defp cidr_match?(peer, network, prefix) do
    {network, prefix} = normalize_network(network, prefix)

    with {peer, bits} <- ip_integer(normalize_ip(peer)),
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

  defp normalize_ip({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    {high >>> 8, high &&& 255, low >>> 8, low &&& 255}
  end

  defp normalize_ip(ip), do: ip

  defp normalize_network({0, 0, 0, 0, 0, 0xFFFF, _, _} = network, prefix)
       when prefix >= 96 do
    {normalize_ip(network), prefix - 96}
  end

  defp normalize_network(network, prefix), do: {network, prefix}

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
