defmodule TeslaMate.Vehicles.Vehicle.PollingIntervalTest do
  use TeslaMate.VehicleCase, async: true

  alias TeslaMate.Vehicles.Vehicle
  alias TeslaMate.Vehicles.Vehicle.Data
  alias TeslaMate.Settings.CarSettings
  alias TeslaMate.Log.{Car, Drive, ChargingProcess}

  defmodule LogStub do
    def insert_charge(_, _), do: {:ok, %TeslaMate.Log.Charge{}}
    def insert_position(_, attrs), do: {:ok, struct(TeslaMate.Log.Position, attrs)}
  end

  defmodule LocationsStub do
    def find_geofence(_), do: nil
  end

  defp data(interval) do
    %Data{
      car: %Car{
        id: 1,
        settings: %CarSettings{polling_interval: interval, use_streaming_api: false}
      },
      last_used: DateTime.utc_now(),
      deps: %{log: LogStub, locations: LocationsStub}
    }
  end

  test "uses the automatic online interval until an explicit frequency is selected" do
    vehicle = online_event(System.os_time(:millisecond), vehicle_state: %{is_user_present: true})

    for {interval, expected} <- [{0, Vehicle.default_interval()}, {5, 5}, {30, 30}, {300, 300}] do
      assert {:keep_state, _, actions} =
               Vehicle.handle_event(
                 :internal,
                 {:update, {:online, vehicle}},
                 :online,
                 data(interval)
               )

      assert {:state_timeout, round(expected), :fetch} in actions
    end
  end

  test "uses the selected frequency for driving and charging collection" do
    now = System.os_time(:millisecond)
    drive = drive_event(now, "D", 30)

    assert {:keep_state, _, actions} =
             Vehicle.handle_event(
               :internal,
               {:update, {:online, drive}},
               {:driving, :available, %Drive{}},
               data(30)
             )

    assert {:state_timeout, 30, :fetch} in actions

    charge = charging_event(now, "Charging", 2.0)

    assert {:next_state, _, _, actions} =
             Vehicle.handle_event(
               :internal,
               {:update, {:online, charge}},
               {:charging, %ChargingProcess{}},
               data(60)
             )

    assert {:state_timeout, 60, :fetch} in actions
  end

  test "changing frequency preserves an existing sleep or error timer" do
    settings = %CarSettings{polling_interval: 5, use_streaming_api: false}

    for state <- [:online, {:suspended, :online}, {:asleep, 30}] do
      assert {:keep_state, updated} =
               Vehicle.handle_event(:info, settings, state, data(300))

      assert updated.car.settings.polling_interval == 5
    end
  end

  test "keeps sleeping and offline state checks on their automatic schedule" do
    for state <- [:asleep, :offline] do
      assert {:keep_state_and_data, actions} =
               Vehicle.handle_event(
                 :internal,
                 {:update, {state, nil}},
                 {state, 30},
                 data(300)
               )

      assert {:state_timeout, round(Vehicle.asleep_interval()), :fetch} in actions
    end
  end

  @tag :capture_log
  test "honors server rate-limit backoff even with a shorter collection interval" do
    ref = make_ref()
    task = %Task{ref: ref, owner: self(), pid: self(), mfa: {Vehicle, :handle_event, 4}}
    data = %{data(5) | task: task}

    assert {:keep_state, _, actions} =
             Vehicle.handle_event(
               :info,
               {ref, {:error, :too_many_request, 120}},
               :online,
               data
             )

    assert {:state_timeout, 120, :fetch} in actions
  end
end
