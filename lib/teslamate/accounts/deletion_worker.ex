defmodule TeslaMate.Accounts.DeletionWorker do
  @moduledoc "Restart-safe account deletion scheduler; deadlines live in PostgreSQL."
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    send(self(), :sweep)
    {:ok, Keyword.get(opts, :interval, 60_000)}
  end

  @impl true
  def handle_info(:sweep, interval) do
    try do
      TeslaMate.Accounts.Lifecycle.purge_expired()
    rescue
      _ -> Logger.error("Account deletion sweep failed; it will retry in one minute")
    catch
      :exit, _ -> Logger.error("Account deletion sweep interrupted; it will retry in one minute")
    end

    Process.send_after(self(), :sweep, interval)
    {:noreply, interval}
  end
end
