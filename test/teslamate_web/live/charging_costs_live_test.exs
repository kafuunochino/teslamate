defmodule TeslaMateWeb.ChargingCostsLiveTest do
  use TeslaMateWeb.ConnCase, async: false

  alias TeslaMate.{ChargeCosts, Fleet, Log, Repo}
  alias TeslaMate.Accounts.UserCar
  alias TeslaMate.Log.ChargingProcess

  setup do
    id = System.unique_integer([:positive])

    {:ok, car} =
      Log.create_car(%{eid: id, vid: id, vin: "COST#{id}", model: "3", efficiency: 0.153})

    charge = charge_fixture(car)
    %{car: car, charge: charge}
  end

  test "adds and edits actual cost, preserves telemetry and survives reopening", %{
    conn: conn,
    car: car,
    charge: charge
  } do
    {:ok, view, _} = live(conn, "/charging?car=#{car.id}")
    assert has_element?(view, "#charge-cost-value-#{charge.id}", "未填写")
    edit(view, charge)

    view |> form("#charge-cost-form", charge_cost: %{cost: "32.50"}) |> render_submit()

    assert has_element?(view, "#charge-cost-value-#{charge.id}", "¥32.50")
    assert has_element?(view, "#charge-cost-notice", "统计已更新")
    assert Repo.get!(ChargingProcess, charge.id).cost == Decimal.new("32.50")

    edit(view, charge)

    render_submit(view, "save_cost", %{
      "charge_cost" => %{"cost" => "31.28", "charge_energy_added" => "999", "car_id" => "0"}
    })

    stored = Repo.get!(ChargingProcess, charge.id)
    assert stored.cost == Decimal.new("31.28")
    assert stored.charge_energy_added == charge.charge_energy_added
    assert stored.start_date == charge.start_date
    assert stored.car_id == car.id

    {:ok, reopened, _} = live(conn, "/charging?car=#{car.id}")
    assert has_element?(reopened, "#charge-cost-value-#{charge.id}", "¥31.28")
  end

  test "distinguishes zero from unknown and excludes unknown charges from average cost", %{
    conn: conn,
    car: car,
    charge: charge,
    current_user: user
  } do
    charge_fixture(car, %{cost: Decimal.new("40.00"), charge_energy_added: Decimal.new("20")})
    report = Fleet.charging(user, car.id)
    assert report.stats.cost_count == 1
    assert Decimal.equal?(report.stats.priced_energy_added, Decimal.new("20"))

    {:ok, view, html} = live(conn, "/charging?car=#{car.id}")
    assert html =~ "¥2.00/kWh"
    edit(view, charge)
    view |> form("#charge-cost-form", charge_cost: %{cost: "0"}) |> render_submit()
    assert has_element?(view, "#charge-cost-value-#{charge.id}", "¥0.00")
    assert Fleet.charging(user, car.id).stats.cost_count == 2

    edit(view, charge)
    view |> form("#charge-cost-form", charge_cost: %{cost: ""}) |> render_submit()
    assert has_element?(view, "#charge-cost-value-#{charge.id}", "未填写")
    assert Repo.get!(ChargingProcess, charge.id).cost == nil
    assert Fleet.charging(user, car.id).stats.cost_count == 1
  end

  test "rejects invalid precision, overflow and non-finite costs", %{
    current_user: user,
    charge: c
  } do
    for value <- ["abc", "0.001", "10000", "-10000", "NaN", "Infinity"] do
      assert {:error, %Ecto.Changeset{valid?: false}} =
               ChargeCosts.update(user, c, %{"cost" => value})

      assert Repo.get!(ChargingProcess, c.id).cost == nil
    end
  end

  test "shows input errors without losing the selected record", %{conn: conn, charge: charge} do
    {:ok, view, _} = live(conn, "/charging")
    edit(view, charge)
    render_submit(view, "save_cost", %{"charge_cost" => %{"cost" => "0.001"}})
    assert has_element?(view, "#charge-cost-errors", "金额最多保留两位小数")
    assert has_element?(view, "#charge-cost-form")
    assert Repo.get!(ChargingProcess, charge.id).cost == nil
  end

  @tag platform_role: :member
  test "prevents edits to an unbound vehicle", %{
    conn: conn,
    charge: charge,
    current_user: user
  } do
    {:ok, view, _} = live(conn, "/charging")
    render_click(view, "edit_cost", %{"id" => to_string(charge.id)})
    refute has_element?(view, "#charge-cost-form")
    assert {:error, :forbidden} = ChargeCosts.update(user, charge, %{"cost" => "25.00"})
    assert Repo.get!(ChargingProcess, charge.id).cost == nil
  end

  @tag platform_role: :member
  test "allows a bound user but rechecks access before saving", %{
    conn: conn,
    car: car,
    charge: charge,
    current_user: user
  } do
    binding = Repo.insert!(%UserCar{user_id: user.id, car_id: car.id})
    {:ok, view, _} = live(conn, "/charging")
    edit(view, charge)
    view |> form("#charge-cost-form", charge_cost: %{cost: "12.34"}) |> render_submit()
    assert Repo.get!(ChargingProcess, charge.id).cost == Decimal.new("12.34")

    edit(view, charge)
    Repo.delete!(binding)
    render_submit(view, "save_cost", %{"charge_cost" => %{"cost" => "99.00"}})
    refute has_element?(view, "#charge-cost-form")
    assert Repo.get!(ChargingProcess, charge.id).cost == Decimal.new("12.34")
  end

  test "does not overwrite a newer cost saved while the editor was open", %{
    conn: conn,
    charge: charge
  } do
    {:ok, view, _} = live(conn, "/charging")
    edit(view, charge)
    charge |> Ecto.Changeset.change(cost: Decimal.new("22.00")) |> Repo.update!()
    view |> form("#charge-cost-form", charge_cost: %{cost: "11.00"}) |> render_submit()
    assert has_element?(view, "#charge-cost-notice", "费用已被更新")
    assert has_element?(view, "#charge-cost-value-#{charge.id}", "¥22.00")
    assert Repo.get!(ChargingProcess, charge.id).cost == Decimal.new("22.00")
  end

  test "waits for charging to finish before accepting a final bill", %{
    conn: conn,
    car: car,
    current_user: user
  } do
    charge = charge_fixture(car, %{end_date: nil})
    {:ok, view, _} = live(conn, "/charging")
    assert has_element?(view, "#charge-cost-edit-#{charge.id}[disabled]")
    render_click(view, "edit_cost", %{"id" => to_string(charge.id)})
    refute has_element?(view, "#charge-cost-form")
    assert {:error, :in_progress} = ChargeCosts.update(user, charge, %{"cost" => "30"})
  end

  defp edit(view, charge) do
    view |> element("#charge-cost-edit-#{charge.id}") |> render_click()
    assert has_element?(view, "#charge-cost-form")
  end

  defp charge_fixture(car, attrs \\ %{}) do
    now = DateTime.utc_now()

    attrs =
      Map.merge(
        %{
          start_date: DateTime.add(now, -3600),
          end_date: DateTime.add(now, -1800),
          charge_energy_added: Decimal.new("8"),
          charge_energy_used: Decimal.new("10"),
          duration_min: 30,
          position: %{date: now, latitude: 0, longitude: 0, car_id: car.id}
        },
        attrs
      )

    %ChargingProcess{car_id: car.id}
    |> ChargingProcess.changeset(attrs)
    |> Repo.insert!()
  end
end
