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

  ## Backward-compatibility switches

  * `EMBED_GRAFANA=false` — disables the proxy entirely. Users hitting
    `/dashboards/*` are 302-redirected to `GRAFANA_PUBLIC_URL` so the legacy
    direct port 3000 still works during a migration.
  * `EMBED_GRAFANA=true` (default) — proxy is active. Unauthenticated users are
    302-redirected to `/sign_in`.

  No env vars are read at compile time, so changes only require a TeslaMate
  restart.
  """

  import Plug.Conn
  require Logger

  alias TeslaMate.HTTP

  @upstream TeslaMateWeb.Config.grafana_upstream()
  @public_grafana_url TeslaMateWeb.Config.grafana_public_url()
  @public_prefix "/dashboards"
  @proxy_user TeslaMateWeb.Config.grafana_proxy_user()
  @token_salt "teslamate-grafana-proxy"
  @token_max_age 60 * 60 * 8
  @hop_by_hop ~w(
    connection keep-alive proxy-authenticate proxy-authorization
    te trailers transfer-encoding upgrade
    set-cookie2
  )

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      not proxy_enabled?() ->
        redirect_unembedded(conn)

      not conn_signed_in?(conn) ->
        redirect_to_sign_in(conn)

      true ->
        do_proxy(conn)
    end
  end

  # ---- routing ------------------------------------------------------------

  defp proxy_enabled?, do: TeslaMateWeb.Config.embed_grafana?()

  defp conn_signed_in?(conn) do
    case conn.assigns[:signed_in?] do
      nil -> false
      signed_in -> !!signed_in
    end
  end

  defp public_grafana_url do
    case @public_grafana_url do
      "" -> nil
      url -> String.trim_trailing(url, "/")
    end
  end

  # ---- fallbacks ----------------------------------------------------------

  defp redirect_to_sign_in(conn) do
    target = Phoenix.Router.Routes.live_path(conn, TeslaMateWeb.SignInLive.Index)

    conn
    |> put_resp_header("location", target)
    |> send_resp(302, "")
    |> halt()
  end

  defp redirect_unembedded(conn) do
    case public_grafana_url() do
      nil ->
        body =
          "<h1>Grafana embedding disabled</h1>" <>
            "<p>EMBED_GRAFANA is set to <code>false</code> but no " <>
            "<code>GRAFANA_PUBLIC_URL</code> is configured. Either set " <>
            "<code>GRAFANA_PUBLIC_URL</code> to the URL your browser can " <>
            "reach Grafana at, or enable <code>EMBED_GRAFANA=true</code> to " <>
            "keep everything inside TeslaMate.</p>"

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(503, body)
        |> halt()

      base ->
        target = base <> rewrite_path(conn.request_path) <> qs(conn.query_string)

        conn
        |> put_resp_header("location", target)
        |> send_resp(302, "")
        |> halt()
    end
  end

  # ---- upstream request ---------------------------------------------------

  defp do_proxy(conn) do
    target = build_target(conn)
    headers = build_headers(conn)
    body = conn_body(conn)
    method = conn.method |> String.downcase() |> String.to_atom()

    case HTTP.request(method, target, headers: headers, body: body,
           receive_timeout: 60_000, pool_timeout: 60_000) do
      {:ok, %Finch.Response{status: status, headers: resp_headers, body: resp_body}} ->
        send_proxied(conn, status, resp_headers, resp_body)

      {:error, reason} ->
        Logger.warning("Grafana proxy failure: #{inspect(reason)}")
        send_resp(conn, 502, "Grafana upstream unavailable")
    end
  end

  defp build_target(conn) do
    @upstream <> rewrite_path(conn.request_path) <> qs(conn.query_string)
  end

  # Rewrite `/dashboards/anything` down to `/anything` before forwarding
  # upstream. Always returns a path beginning with a single `/`.
  defp rewrite_path("/" <> _ = path) do
    cond do
      path == @public_prefix -> "/"
      String.starts_with?(path, @public_prefix <> "/") ->
        rest = path |> String.replace_prefix(@public_prefix, "") |> String.trim_leading("/")
        if rest == "", do: "/", else: "/" <> rest
      true -> path
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
        # We send *both* the user identity (for display) AND a signed token that
        # Grafana can verify (see grafana/Dockerfile — `GF_AUTH_PROXY_HEADER_NAME`
        # is the user; the token comes via the cookie we set on `do_proxy/1`).
        {"x-teslamate-user", @proxy_user},
        {"x-teslamate-token", mint_proxy_token(conn)},
        {"x-forwarded-for", forwarded_for(conn)},
        {"x-forwarded-proto", forwarded_proto(conn)}
      ]
  end

  # Mint a short-lived signed token that the operator-side proxy (Nginx,
  # Caddy) can verify before forwarding to Grafana. Without an external
  # verifier, this token is still useful as a defence-in-depth signal:
  # anyone with raw docker-network access to grafana:3000 would have to also
  # know the cookie signing_salt (which lives in `endpoint.ex` and is rotated
  # on every release) to forge one.
  defp mint_proxy_token(conn) do
    payload = %{
      user: @proxy_user,
      ip: conn.private[:client_ip] || "unknown",
      exp: System.system_time(:second) + @token_max_age
    }

    Phoenix.Token.sign(TeslaMateWeb.Endpoint, @token_salt, payload)
  rescue
    _ -> ""
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

  # ---- upstream response --------------------------------------------------

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
    |> put_resp_headers(headers)
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("referrer-policy", "same-origin")
    |> set_proxy_cookie()
    |> send_resp(status, resp_body)
    |> halt()
  end

  # Set a short-lived, HttpOnly, SameSite=Strict cookie that the upstream
  # proxy (Nginx, Caddy) can verify before forwarding to Grafana. The cookie
  # value is a signed token tied to the user's session via the endpoint's
  # signing salt.
  defp set_proxy_cookie(conn) do
    token = mint_proxy_token(conn)

    Plug.Conn.put_resp_cookie(conn, "teslamate_grafana_token", token,
      max_age: @token_max_age,
      http_only: true,
      secure: true,
      same_site: "Strict",
      path: "/dashboards"
    )
  end

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
  end

  # Rewrites `Location` headers returned by Grafana so the browser always
  # navigates within TeslaMate's `/dashboards/*` prefix.
  #
  #   * relative `/foo`      → `/dashboards/foo`
  #   * relative `foo`       → `/dashboards/foo`
  #   * absolute pointing at internal upstream (e.g. `http://grafana:3000/x`
  #     or the GRAFANA_PUBLIC_URL host) → `/dashboards/x`
  #   * absolute pointing at any *other* host → returned unchanged so the
  #     browser follows it normally (cross-origin webhook etc.)
  defp rewrite_location(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{host: nil, path: path} ->
        @public_prefix <> ensure_leading_slash(path)

      %URI{} = uri ->
        if same_origin?(uri) do
          @public_prefix <>
            ensure_leading_slash(uri.path || "/") <>
            qs(uri.query)
        else
          value
        end
    end
  end

  defp rewrite_location(other), do: to_string(other)

  defp same_origin?(%URI{host: h, port: p}) do
    %URI{host: up_host, port: up_port} = URI.parse(@upstream)
    pub_host = public_grafana_url() || up_host
    %URI{host: parsed_pub_host, port: pub_port} = URI.parse(pub_host)

    h in [up_host, parsed_pub_host] and
      (p == up_port or p == pub_port or is_nil(p))
  end

  # ---- string helpers -----------------------------------------------------

  defp qs(nil), do: ""
  defp qs(""), do: ""
  defp qs(qs), do: "?" <> qs

  defp ensure_leading_slash("/" <> _ = v), do: v
  defp ensure_leading_slash(v), do: "/" <> v
end