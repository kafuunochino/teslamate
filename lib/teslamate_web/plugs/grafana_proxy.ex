defmodule TeslaMateWeb.Plugs.GrafanaProxy do
  @moduledoc """
  Reverse-proxies requests from `TeslaMateWeb.Router` to the internal Grafana
  service (default `http://grafana:3000`).

  The plug must always sit behind `TeslaMateWeb.Plugs.RequireSignedIn` so this
  is gated by the TeslaMate sign-in flow.

  The TeslaMate browser only ever sees `/dashboards/*` — upstream Grafana URLs
  contained in redirect `Location` headers are rewritten so the user cannot
  reach Grafana by typing a direct URL.

  Configure Grafana with `GF_AUTH_PROXY_ENABLED=true` and
  `GF_AUTH_PROXY_HEADER_NAME=X-Teslamate-User` (see `grafana/Dockerfile`).
  Each request signed-in to TeslaMate will therefore appear as
  `X-Teslamate-User: <token>` to Grafana which accepts it via its auth_proxy.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]
  require Logger

  alias TeslaMate.HTTP

  @upstream System.get_env("GRAFANA_UPSTREAM", "http://grafana:3000")
  @public_prefix "/dashboards"
  @proxy_user System.get_env("GRAFANA_PROXY_USER", "teslamate@local")
  @enabled_env System.get_env("EMBED_GRAFANA", "true")
  @hop_by_hop ~w(
    connection keep-alive proxy-authenticate proxy-authorization
    te trailers transfer-encoding upgrade
    set-cookie2
  )

  def init(opts), do: opts

  def call(conn, _opts) do
    if proxy_enabled?() and conn_signed_in?(conn) do
      do_proxy(conn)
    else
      # Backward-compatible default: a TeslaMate deployment may not have the
      # reverse-proxy plumbing in place. If proxy is disabled just fall back to
      # a redirect so the user's browser keeps working (legacy direct port 3000
      # access). When `EMBED_GRAFANA=true` but the user is signed out, we send
      # them to /sign_in.
      cond do
        not proxy_enabled?() -> redirect_unembedded(conn)
        true -> redirect_to_sign_in(conn)
      end
    end
  end

  defp proxy_enabled? do
    String.downcase(@enabled_env) in ~w(1 true yes on)
  end

  defp conn_signed_in?(conn) do
    case conn.assigns[:signed_in?] do
      nil -> false
      signed_in -> !!signed_in
    end
  end

  defp redirect_unembedded(conn) do
    target = @upstream <> rewrite_path(conn.request_path) <> qs(conn.query_string)

    conn
    |> put_resp_header("location", target)
    |> send_resp(302, "")
    |> halt()
  end

  defp redirect_to_sign_in(conn) do
    target = Phoenix.Router.Routes.live_path(conn, TeslaMateWeb.SignInLive.Index)

    conn
    |> put_resp_header("location", target)
    |> send_resp(302, "")
    |> halt()
  end

  defp do_proxy(conn) do
    target = build_target(conn)
    headers = build_headers(conn)
    body = conn_body(conn)

    method =
      conn.method
      |> String.downcase()
      |> String.to_atom()

    case HTTP.request(method, target, headers: headers, body: body,
           receive_timeout: 60_000, pool_timeout: 60_000) do
      {:ok, %Finch.Response{status: status, headers: resp_headers, body: resp_body}} ->
        send_proxied(conn, status, resp_headers, resp_body)

      {:error, reason} ->
        Logger.warning("Grafana proxy failure: #{inspect(reason)}")
        send_resp(conn, 502, "Grafana upstream unavailable")
    end
  end

  defp qs(""), do: ""
  defp qs(qs), do: "?" <> qs

  # ---- helpers ------------------------------------------------------------

  defp build_target(conn) do
    qs = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    @upstream <> rewrite_path(conn.request_path) <> qs
  end

  # Rewrite `/dashboards/anything` down to `/anything` before forwarding
  # upstream and always include a leading slash.
  defp rewrite_path("/" <> _ = path) do
    case path do
      @public_prefix ->
        "/"

      @public_prefix <> rest ->
        "/" <> String.trim_leading(rest, "/")

      _ ->
        path
    end
  end

  defp build_headers(conn) do
    forwarded =
      for {k, v} <- conn.req_headers,
          String.downcase(to_string(k)) in ~w(
            accept accept-encoding accept-language cookie referer origin
          ),
          do: {to_string(k), v}

    forwarded ++
      [
        {"host", host(@upstream)},
        # Tell Grafana that the incoming request has already been authenticated.
        {"x-teslamate-user", @proxy_user},
        {"x-forwarded-for", forwarded_for(conn)},
        {"x-forwarded-proto", forwarded_proto(conn)}
      ]
  end

  defp host(url) do
    %URI{host: h, port: p} = URI.parse(url)
    if p && p not in [nil, 80, 443], do: "#{h}:#{p}", else: h
  end

  defp forwarded_for(conn) do
    case List.keyfind(conn.req_headers, "x-forwarded-for", 0) do
      {_, v} -> to_string(v)
      nil -> to_string(conn.remote_ip)
    end
  end

  defp forwarded_proto(conn) do
    case List.keyfind(conn.req_headers, "x-forwarded-proto", 0) do
      {_, v} -> to_string(v)
      nil -> "http"
    end
  end

  defp conn_body(%Plug.Conn{method: m})
       when m in ["GET", "HEAD", "OPTIONS", "DELETE"],
       do: ""

  defp conn_body(conn) do
    case read_body(conn) do
      {:ok, body, _conn} -> body || ""
      {:error, _reason} -> ""
    end
  end

  defp send_proxied(conn, status, resp_headers, resp_body) do
    headers =
      for {k, v} <- resp_headers, into: [] do
        lk = String.downcase(to_string(k))

        cond do
          lk in @hop_by_hop -> nil
          lk == "location" -> {lk, rewrite_location(v)}
          lk == "content-length" -> {lk, Integer.to_string(byte_size(resp_body))}
          lk == "transfer-encoding" -> nil
          true -> {lk, to_string(v)}
        end
      end
      |> Enum.reject(&is_nil/1)

    conn
    |> put_status(status)
    |> Enum.reduce(headers, fn {k, v}, c -> put_resp_header(c, k, v) end)
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("referrer-policy", "same-origin")
    |> send_resp(status, resp_body)
    |> halt()
  end

  # Any relative Location from Grafana is rewritten back under the public prefix.
  defp rewrite_location(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{host: nil} -> @public_prefix <> ensure_leading_slash(value)
      _ -> value
    end
  end

  defp rewrite_location(other), do: to_string(other)

  defp ensure_leading_slash("/" <> _ = v), do: v
  defp ensure_leading_slash(v), do: "/" <> v
end
