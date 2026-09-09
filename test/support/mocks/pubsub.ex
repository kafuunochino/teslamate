defmodule PubSubMock do
  use GenServer

  defstruct [:pid, :last_event]
  alias __MODULE__, as: State

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  def broadcast(name, server, topic, message) do
    GenServer.call(name, {:broadcast, server, topic, message})
  end

  # Callbacks

  @impl true
  def init(opts) do
    {:ok, %State{pid: Keyword.fetch!(opts, :pid)}}
  end

  @impl true

  def handle_call({:broadcast, _, "Elixir.TeslaMate.Vehicles.Vehicle/fetch/" <> _, _}, _, state) do
    {:reply, :ok, state}
  end

  def handle_call({:broadcast, _, _, _} = event, _from, %State{pid: pid} = state) do
    # State assertions ignore timestamp-only refreshes but retain the original payload.
    comparable =
      case event do
        {:broadcast, server, topic, %TeslaMate.Vehicles.Vehicle.Summary{} = summary} ->
          {:broadcast, server, topic, %{summary | data_updated_at: nil}}

        _ ->
          event
      end

    unless comparable == state.last_event, do: send(pid, {:pubsub, event})
    {:reply, :ok, %State{state | last_event: comparable}}
  end
end
