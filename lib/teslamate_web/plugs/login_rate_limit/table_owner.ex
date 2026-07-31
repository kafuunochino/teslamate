defmodule TeslaMateWeb.Plugs.LoginRateLimit.TableOwner do
  @moduledoc false

  use GenServer

  @table :teslamate_login_rate_limits

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
          {:ok, pid} -> ready(pid)
          {:error, {:already_started, pid}} -> ready(pid)
        end

      pid ->
        ready(pid)
    end
  end

  @impl GenServer
  def init(:ok) do
    @table =
      :ets.new(@table, [:named_table, :public, :duplicate_bag, read_concurrency: true])

    {:ok, @table}
  end

  @impl GenServer
  def handle_call(:ready, _from, table), do: {:reply, :ok, table}

  defp ready(pid), do: GenServer.call(pid, :ready)
end
