defmodule TeslaMateWeb.Plugs.LoginRateLimit do
  @moduledoc """
  Brute-force protection for the `/sign_in` LiveView.

  ## How it works

  Failures are tracked per-IP and per-email using a sliding time window
  (`TESLAMATE_LOGIN_WINDOW_SECONDS`, default 10 minutes). Counts live in a
  single ETS table (`:ets.duplicate_bag`) that every Phoenix process reads.
  Buckets expire naturally once the oldest hit falls out of the window.

  When a request is accepted (below the threshold), the plug stores
  `{ip, email}` in `conn.private[:login_rate_limit]` so that the LiveView
  can later call `record_failure/1` or `record_success/1` without having to
  re-parse the body.

  ## Tuning (env vars)

    * `TESLAMATE_LOGIN_MAX_PER_IP`     — default `10`
    * `TESLAMATE_LOGIN_MAX_PER_EMAIL`  — default `5`
    * `TESLAMATE_LOGIN_WINDOW_SECONDS` — default `600` (10 minutes)

  ## Lifecycle

  Apply via the `:login_rate_limit` pipeline **before** `TeslaMateWeb.Plugs.RequireSignedIn`
  on the `/sign_in` route only. This keeps the gating local to authentication
  and avoids slowing down regular page loads.
  """

  import Plug.Conn
  require Logger

  alias TeslaMateWeb.Config

  @table :teslamate_login_rate_limits

  def init(opts), do: opts

  # Called by the Phoenix pipeline when a /sign_in request arrives.
  def call(conn, _opts) do
    ensure_started()
    ip = client_ip(conn)
    email = extract_email(conn)

    if blocked?(ip, email) do
      retry = retry_after(ip, email)
      Logger.warning("[login-rate-limit] blocked ip=#{ip} email=#{mask(email)} retry=#{retry}s")

      conn
      |> put_resp_header("retry-after", Integer.to_string(retry))
      |> put_resp_header("content-type", "application/json")
      |> send_resp(429, ~s({"error":"too_many_attempts","retry_after":#{retry}}))
      |> halt()
    else
      # Stash the IP/email so the LiveView can call record_failure/success
      # without re-parsing the request body.
      conn
      |> Plug.Conn.put_private(:login_rate_limit, {ip, email})
    end
  end

  # ---- public API (called from the LiveView or Auth context) --------------

  @doc """
  Increment the failure counter for the IP/email stored on `conn.private`.
  """
  def record_failure(conn) do
    {ip, email} = conn.private[:login_rate_limit] || {nil, nil}
    bump_count(ip, email)
  end

  @doc """
  Returns `:ok | {:error, :rate_limited, retry_after_seconds}`. Use this
  directly from a LiveView (which does not flow through the plug pipeline)
  to gate the submit handler.
  """
  def check(ip, email) when is_binary(ip) do
    ensure_started()

    if blocked?(ip, email) do
      {:error, :rate_limited, retry_after(ip, email)}
    else
      :ok
    end
  end

  def check(_ip, _email), do: :ok

  @doc """
  Same as `record_failure/1` but accepts the IP and email explicitly. Use
  this from outside the plug pipeline (e.g. from a LiveView process that no
  longer has the conn).
  """
  def record_failure(ip, email) when is_binary(ip) do
    bump_count(ip, email)
  end

  @doc """
  Reset the failure counter for the IP/email stored on `conn.private`. Call
  this when a sign-in is successful so legitimate users are not penalised
  by their own earlier typos.
  """
  def record_success(conn) do
    {_ip, email} = conn.private[:login_rate_limit] || {nil, nil}
    if email, do: :ets.match_delete(@table, {{:email, email}, :_})
    :ok
  end

  @doc """
  Same as `record_success/1` but with explicit ip/email.
  """
  def record_success(_ip, email) when is_binary(email) do
    :ets.match_delete(@table, {{:email, email}, :_})
    :ok
  end

  def record_success(_ip, _nil), do: :ok

  defp bump_count(ip, email) do
    ensure_started()
    now = System.system_time(:second)
    :ets.insert(@table, {{:ip, ip}, now})
    if email, do: :ets.insert(@table, {{:email, email}, now})
    :ok
  end

  @doc """
  Test/admin introspection: returns the current hit count for the given IP.
  """
  def hit_count(:ip, ip), do: count_hits({:ip, ip})
  def hit_count(:email, email) when is_binary(email), do: count_hits({:email, email})

  @doc "Ensures the underlying ETS table exists. Idempotent."
  def ensure_started do
    case :ets.info(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :duplicate_bag, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  # ---- helpers ------------------------------------------------------------

  defp client_ip(conn) do
    case List.keyfind(conn.req_headers, "x-forwarded-for", 0) do
      {_, v} when is_binary(v) ->
        v |> String.split(",") |> List.first() |> String.trim()

      _ ->
        to_string(conn.remote_ip)
    end
  end

  defp extract_email(conn) do
    with %{"tokens" => %{"email" => email}} when is_binary(email) <- conn.body_params do
      String.downcase(email)
    else
      _ -> nil
    end
  end

  defp mask(nil), do: "(none)"
  defp mask(email) do
    case String.split(email, "@") do
      [local, domain] -> String.slice(local, 0, 2) <> "***@" <> domain
      _ -> "***"
    end
  end

  defp max_per_ip, do: Config.max_login_per_ip()
  defp max_per_email, do: Config.max_login_per_email()
  defp window_seconds, do: Config.login_window_seconds()

  defp blocked?(ip, email) do
    cutoff = System.system_time(:second) - window_seconds()
    count_hits({:ip, ip}, cutoff) >= max_per_ip() or
      (email != nil and count_hits({:email, email}, cutoff) >= max_per_email())
  end

  defp retry_after(ip, _email) do
    cutoff = System.system_time(:second) - window_seconds()

    case :ets.match(@table, {{:ip, ip}, :"$1"}) |> Enum.map(&hd/1) |> Enum.filter(&(&1 >= cutoff)) |> Enum.min() do
      oldest -> max(1, oldest + window_seconds() - System.system_time(:second))
    end
  rescue
    _ -> window_seconds()
  end

  defp count_hits(key, cutoff \\ nil) do
    match_spec =
      case cutoff do
        nil -> {{key, :"$1"}, [:"$_"]}
        c -> {{key, :"$1"}, [{:>=, :"$1", c}], [:"$_"]}
      end

    :ets.select(@table, [match_spec])
    |> length()
  end
end