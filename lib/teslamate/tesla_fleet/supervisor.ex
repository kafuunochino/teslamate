defmodule TeslaMate.TeslaFleet.Supervisor do
  use Supervisor
  alias TeslaMate.TeslaFleet.Config

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    children = case Config.get() do
      {:ok, c} ->
        proxy = if is_binary(c["proxy_ca_file"]) do
          Finch.child_spec(name: TeslaMate.TeslaFleet.ProxyHTTP,
            pools: %{default: [size: 1, conn_opts: [transport_opts: [
              cacertfile: c["proxy_ca_file"], verify: :verify_peer
            ]]]})
        end
        mqtt = if c["mqtt_host"] && c["mqtt_password"] do
          Supervisor.child_spec({Tortoise311.Connection, [
            client_id: "teslamate-fleet-reader", clean_session: false,
            server: {Tortoise311.Transport.Tcp, host: c["mqtt_host"], port: c["mqtt_port"] || 1883},
            user_name: c["mqtt_username"], password: c["mqtt_password"],
            subscriptions: [{"fleet/+/v/+", 1}],
            handler: {TeslaMate.TeslaFleet.MqttHandler, []}
          ]}, id: :tesla_fleet_mqtt)
        end
        [proxy, mqtt, TeslaMate.TeslaFleet.Maintenance] |> Enum.reject(&is_nil/1)
      _ -> []
    end
    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule TeslaMate.TeslaFleet.MqttHandler do
  use Tortoise311.Handler
  @impl true
  def handle_message(["fleet", vin, "v", field], payload, state) do
    TeslaMate.TeslaFleet.Readings.ingest(vin, field, payload)
    {:ok, state}
  end
  def handle_message(_, _, state), do: {:ok, state}
end

defmodule TeslaMate.TeslaFleet.Maintenance do
  use GenServer
  require Logger
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    Process.send_after(self(), :refresh, 60_000)
    {:ok, nil}
  end
  @impl true
  def handle_info(:refresh, state) do
    case TeslaMate.TeslaFleet.refresh_if_needed() do
      {:error, reason} -> Logger.warning("Tesla Fleet: " <> TeslaMate.TeslaFleet.error_message(reason))
      _ -> :ok
    end
    Process.send_after(self(), :refresh, 300_000)
    {:noreply, state}
  end
end
