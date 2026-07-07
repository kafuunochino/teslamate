defmodule TeslaMate.Auth.LoginAudit do
  @moduledoc """
  Append-only in-memory audit log of every `/sign_in` attempt.

  Entries are kept in an ETS ring buffer (default 100 rows, see
  `TeslaMateWeb.Config.login_audit_capacity/0`) so the data structure
  never grows without bound. The buffer is exposed via `recent/1` so a
  future UI can show the last few attempts, and so operators can inspect
  it from `IEx` while debugging.

  We deliberately do not persist this to PostgreSQL because:

    * there is no UI to display it (yet)
    * adding a table would change the schema and conflict with the user's
      requirement that upgrades remain backward compatible
    * the recent buffer is enough to detect obvious attacks and to feed
      external log aggregation (Docker/K8s picks it up via `Logger`)

  For long-term storage operators should pipe `Logger.metadata[:audit]`
  events to their central log.
  """

  require Logger

  @table :teslamate_login_audit

  defstruct [:timestamp, :ip, :email, :outcome, :reason]

  @type outcome :: :success | :failure | :blocked

  @doc "Idempotent. Called once at boot."
  def ensure_started do
    case :ets.info(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :duplicate_bag, write_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  @doc """
  Record a sign-in attempt. `entry` is a keyword list or map with keys
  `:ip`, `:email`, `:outcome`, `:reason` (all required except `:reason`).
  """
  def record(%{ip: _, email: _, outcome: outcome} = entry)
      when outcome in [:success, :failure, :blocked] do
    ensure_started()

    timestamp = DateTime.utc_now()
    full = struct!(__MODULE__, Map.put(entry, :timestamp, timestamp))

    Logger.log(audit_level(outcome), fn ->
      "[login-audit] #{outcome} ip=#{full.ip} email=#{mask(full.email)} reason=#{inspect(full.reason)}"
    end)

    key = {DateTime.to_unix(timestamp, :microsecond), :erlang.unique_integer()}
    :ets.insert(@table, {key, full})
    trim_to_capacity()
    :ok
  end

  @doc "Return the last `n` (default 50) audit entries, newest first."
  def recent(n \\ 50) do
    ensure_started()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_k, v} -> v end)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
    |> Enum.take(n)
  end

  @doc "Erase all audit history. Used by tests."
  def reset do
    ensure_started()
    :ets.delete_all_objects(@table)
    :ok
  end

  # ---- internals ----------------------------------------------------------

  defp trim_to_capacity do
    cap = capacity()
    size = :ets.info(@table, :size)

    if size > cap do
      # We always store newest at the end. Delete oldest by extracting the
      # first (size - cap) entries sorted by timestamp.
      to_delete =
        @table
        |> :ets.tab2list()
        |> Enum.sort_by(fn {_k, v} -> v.timestamp end, DateTime)
        |> Enum.take(size - cap)
        |> Enum.map(fn {k, _v} -> k end)

      Enum.each(to_delete, fn k -> :ets.delete(@table, k) end)
    end
  end

  defp capacity, do: TeslaMateWeb.Config.login_audit_capacity()

  defp audit_level(:success), do: :info
  defp audit_level(:failure), do: :warning
  defp audit_level(:blocked), do: :warning

  defp mask(nil), do: "(none)"
  defp mask(email) do
    case String.split(email, "@") do
      [local, domain] -> String.slice(local, 0, 2) <> "***@" <> domain
      _ -> "***"
    end
  end
end