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

  When `TESLAMATE_TRUSTED_PROXIES` is unset, the plug treats *every* peer
  as trusted — fine for direct LAN access, **insecure** for any deployment
  that is reachable from the internet.
  """

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
    peer = to_string(conn.remote_ip)

    if trusted_proxy?(peer) do
      case List.keyfind(conn.req_headers, "x-forwarded-for", 0) do
        {_, value} when is_binary(value) ->
          value |> String.split(",") |> List.first() |> String.trim()

        _ ->
          peer
      end
    else
      peer
    end
  end

  # ---- trusted-proxy matching --------------------------------------------

  defp trusted_proxies do
    case TeslaMateWeb.Config.trusted_proxies() do
      "" -> []
      list ->
        list
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.flat_map(&expand/1)
    end
  end

  # Expand a CIDR like "172.18.0.0/16" into a list of `inet:ip_address()`
  # ranges; for plain IPs just return a single-entry list.
  defp expand(entry) do
    case String.split(entry, "/") do
      [ip] -> [parse_ip(ip) || entry]
      [ip, prefix] -> cidr_range(ip, String.to_integer(prefix))
      _ -> []
    end
  end

  defp parse_ip(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, parsed} -> parsed
      _ -> nil
    end
  end

  defp cidr_range(ip, prefix) when prefix in 0..32 do
    case parse_ip(ip) do
      nil -> []
      _ -> [{parse_ip(ip), prefix}]
    end
  end

  defp cidr_range(_, _), do: []

  defp trusted_proxy?(peer_str) do
    proxies = trusted_proxies()
    proxies == [] or Enum.any?(proxies, &matches?(peer_str, &1))
  end

  defp matches?(peer_str, entry) when is_tuple(entry) do
    {ip, prefix} = entry
    parsed_peer = parse_ip(peer_str)

    cond do
      is_nil(parsed_peer) -> false
      prefix == 0 -> true
      true ->
        masked_peer = mask(parsed_peer, prefix)
        masked_entry = mask(ip, prefix)
        masked_peer == masked_entry
    end
  end

  defp matches?(peer_str, entry) when is_binary(entry) do
    peer_str == entry
  end

  defp mask({a, _b, _c, _d}, prefix) when prefix <= 8, do: {a_band(a, prefix), 0, 0, 0}
  defp mask({a, b, _c, _d}, prefix) when prefix <= 16, do: {a, b_band(b, prefix - 8), 0, 0}
  defp mask({a, b, c, _d}, prefix) when prefix <= 24, do: {a, b, c_band(c, prefix - 16), 0}
  defp mask({a, b, c, d}, prefix) when prefix <= 32, do: {a, b, c, d_band(d, prefix - 24)}
  defp mask(_, _), do: nil

  defp a_band(a, p), do: Bitwise.band(a, Bitwise.<<<(-1, 8 - p))
  defp b_band(b, p), do: Bitwise.band(b, Bitwise.<<<(-1, 8 - p))
  defp c_band(c, p), do: Bitwise.band(c, Bitwise.<<<(-1, 8 - p))
  defp d_band(d, p), do: Bitwise.band(d, Bitwise.<<<(-1, 8 - p))

  # ---- session bridge ----------------------------------------------------

  defp maybe_put_session(%Plug.Conn{} = conn) do
    case get_session(conn) do
      %{} -> put_session(conn, :client_ip, conn.private[:client_ip])
      _ -> conn
    end
  rescue
    _ -> conn
  end
end