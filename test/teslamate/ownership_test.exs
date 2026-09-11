defmodule TeslaMate.OwnershipTest do
  use TeslaMate.DataCase, async: false
  alias TeslaMate.{Accounts, Fleet, Locations, Log, Repo}
  import Mock
  alias TeslaMate.Accounts.User
  alias TeslaMate.Log.ChargingProcess

  setup do
    now = DateTime.utc_now()

    users =
      for prefix <- ["first", "second"] do
        Repo.insert!(%User{
          email: "#{prefix}-#{System.unique_integer([:positive])}@example.com",
          name: prefix,
          password_hash: "test-only",
          password_changed_at: now,
          role: :admin
        })
      end

    [first, second] = users

    cars =
      Enum.map(users, fn user ->
        id = System.unique_integer([:positive])
        {:ok, car} = Log.create_car(%{eid: id, vid: id, vin: "VIN#{id}"})
        {:ok, _} = Accounts.grant_car(user, user, car.id)
        car
      end)

    [car1, car2] = cars
    %{first: first, second: second, car1: car1, car2: car2}
  end

  defp fence(user, name, extra \\ %{}) do
    {:ok, f} =
      Locations.create_geofence(
        user,
        Map.merge(
          %{
            name: name,
            latitude: 26.647,
            longitude: 106.63,
            radius: 150
          },
          extra
        )
      )

    f
  end

  defp charge(car) do
    {:ok, charge} =
      Log.start_charging_process(
        car,
        %{date: DateTime.utc_now(), latitude: 26.647, longitude: 106.63},
        lookup_address: false
      )

    {:ok, charge} =
      Log.update_charging_process(charge, %{charge_energy_added: 10, duration_min: 30})

    charge
  end

  test "exclusive ownership rejects overwriting an existing owner", %{
    first: first,
    second: second,
    car1: car
  } do
    assert {:error, :vehicle_already_bound} = Accounts.grant_car(second, second, car.id)
    assert Repo.get_by!(Accounts.UserCar, car_id: car.id).user_id == first.id
    member = second |> Ecto.Changeset.change(role: :member) |> Repo.update!()
    refute Accounts.can_access_car?(member, car.id)
    assert Fleet.home(member, car.id).car.id != car.id
    {:ok, drive} = Log.start_drive(car)
    assert Fleet.trip(member, drive.id) == nil
  end

  test "fence IDs, coordinates and fee rules remain owner scoped even for administrators", %{
    first: first,
    second: second
  } do
    own = fence(first, "Private Home", %{user_id: second.id})
    other = fence(second, "Other Private Home")
    assert own.user_id == first.id
    assert Enum.map(Locations.list_geofences(first), & &1.id) == [own.id]
    refute Locations.get_geofence(first, other.id)
    assert {:error, :forbidden} = Locations.update_geofence(first, other, %{name: "overwrite"})
    assert {:error, :forbidden} = Locations.delete_geofence(first, other.id)
    assert {:error, :forbidden} = Locations.calculate_charge_costs(first, other)
    assert Locations.get_geofence(second, other.id).name == "Other Private Home"
    assert Locations.get_geofence(first, "invalid") == nil
  end

  test "overlapping fences never attach to or price another account's charges", %{
    first: first,
    second: second,
    car1: car1,
    car2: car2
  } do
    c1 = charge(car1)
    c2 = charge(car2)
    g1 = fence(first, "Home A", %{cost_per_unit: 1, billing_type: :per_kwh})
    assert Repo.get!(ChargingProcess, c1.id).geofence_id == g1.id
    refute Repo.get!(ChargingProcess, c2.id).geofence_id
    assert Locations.count_charging_processes_without_costs(g1) == 1
    assert :ok = Locations.calculate_charge_costs(first, g1)
    assert Decimal.equal?(Repo.get!(ChargingProcess, c1.id).cost, 10)
    assert Repo.get!(ChargingProcess, c2.id).cost == nil
    g2 = fence(second, "Home B", %{cost_per_unit: 3, billing_type: :per_kwh})
    assert :ok = Locations.calculate_charge_costs(second, g2)
    assert Decimal.equal?(Repo.get!(ChargingProcess, c2.id).cost, 30)
    assert Repo.get!(ChargingProcess, c1.id).geofence_id == g1.id

    assert Locations.find_geofence(%{car_id: car1.id, latitude: 26.647, longitude: 106.63}).id ==
             g1.id

    assert Locations.find_geofence(%{car_id: car2.id, latitude: 26.647, longitude: 106.63}).id ==
             g2.id
  end

  test "new car ownership discards the previous account's private fence labels", %{
    first: first,
    second: second,
    car1: car
  } do
    c = charge(car)
    g1 = fence(first, "Previous Home")
    assert Repo.get!(ChargingProcess, c.id).geofence_id == g1.id
    assert :ok = Accounts.revoke_car(second, first, car.id)
    assert {:ok, _} = Accounts.grant_car(second, second, car.id)
    assert Repo.get!(ChargingProcess, c.id).geofence_id == nil
  end

  test "cached live summaries hide private fence names after an ownership change", %{
    first: first,
    second: second,
    car1: car
  } do
    own = fence(first, "Private Cached Home")
    summary = %TeslaMate.Vehicles.Vehicle.Summary{car: car, geofence: own}

    with_mock TeslaMate.Vehicles, [:passthrough],
      list: fn -> [summary] end,
      summary: fn _ -> summary end do
      assert Fleet.home(first, car.id).live.geofence.id == own.id
      assert :ok = Accounts.revoke_car(second, first, car.id)
      assert {:ok, _} = Accounts.grant_car(second, second, car.id)
      assert Fleet.home(second, car.id).live.geofence == nil
      assert Fleet.driving(second, car.id).live.geofence == nil
    end
  end

  test "a disabled account cannot read or mutate its fences with a stale struct", %{first: first} do
    g = fence(first, "Home")
    Repo.update_all(from(u in User, where: u.id == ^first.id), set: [status: :disabled])
    assert Locations.list_geofences(first) == []
    assert {:error, :forbidden} = Locations.update_geofence(first, g, %{radius: 100})
    assert {:error, :forbidden} = Locations.create_geofence(first, %{name: "Denied"})
  end
end
