defmodule TeslaMateWeb.Plugs.ApiOriginCheck do
  @moduledoc """
  Defence-in-depth for `/api/*` routes.

  The existing `protect_from_forgery` only fires on browser requests that
  include a CSRF token. Browser-issued `fetch()` calls always include
  `Origin` (or `Referer`) headers, while programmatic curl-style attacks
  either omit them or forge them.

  This plug blocks any `POST`, `PUT`, `PATCH` or `DELETE` whose `Origin` or
  `Referer` host does **not** match the host the request is hitting. To
  avoid lockouts the check is gated on `TESLAMATE_API_ORIGIN_CHECK=true` so
  plain curl-from-LAN users (rare) can disable it.

  For HEAD/GET the body cannot mutate state, so we skip the check.
  """

  import Plug.Conn
  require Logger

  @mutating ~w(POST PUT PATCH DELETE)

  def init(opts), do: opts

  def call(conn, _opts) do
    if enabled?() and conn.method in @mutating do
      enforce(conn)
    else
      conn
    end
  end

  # ---- internal ---------------------------------------------------------

  defp enabled?, do: TeslaMateWeb.Config.api_origin_check?()

  defp enforce(conn) do
    host = conn.host

    case trusted_origin?(conn, host) do
      true ->
        conn

      false ->
        Logger.warning(
          "[api-origin] rejected #{conn.method} #{conn.request_path} from " <>
            "origin=#{origin(conn)} referer=#{List.keyget(conn.req_headers, "referer", 0)} host=#{host}"
        )

        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(403, ~s({"error":"forbidden_origin"}))
        |> halt()
    end
  end

  defp trusted_origin?(conn, host) do
    case origin(conn) do
      nil ->
        # No Origin header: fall back to Referer host. Some browsers omit
        # Origin on same-origin POSTs but include Referer.
        case List.keyfind(conn.req_headers, "referer", 0) do
          {_, referer} when is_binary(referer) ->
            case URI.parse(referer) do
              %URI{host: h} when is_binary(h) -> h == host
              _ -> false
            end

          _ ->
            # No Origin and no Referer. Allow only when the operator has
            # explicitly opted out (TESLAMATE_API_ORIGIN_CHECK=false), which
            # this plug already handles above.
            false
        end

      origin_host ->
        origin_host == host
    end
  end

  defp origin(conn) do
    case List.keyfind(conn.req_headers, "origin", 0) do
      {_, v} when is_binary(v) ->
        case URI.parse(v) do
          %URI{host: h} when is_binary(h) -> h
          _ -> nil
        end

      _ ->
        nil
    end
  end
end