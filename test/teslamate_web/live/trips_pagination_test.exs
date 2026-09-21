defmodule TeslaMateWeb.TripsPaginationTest do
  use TeslaMateWeb.ConnCase, async: false

  alias TeslaMate.{AccountFixtures, Fleet, Log, Repo}
  alias TeslaMate.Log.Drive

  setup do
    %{car: create_car()}
  end

  test "all matching trips remain reachable beyond the old limit with stable ordering", %{
    current_user: user,
    car: car
  } do
    ids = insert_drives(car, 161)

    reports = for page <- 1..9, do: Fleet.trips(user, car.id, 30, page)
    assert Enum.flat_map(reports, &Enum.map(&1.drives, fn drive -> drive.id end)) == ids

    for report <- reports do
      assert report.stats.count == 161
      assert report.stats.distance == 161.0
      assert report.pagination.total_count == 161
      assert report.pagination.total_pages == 9
      assert report.pagination.page_size == 20
      page_ids = Enum.map(report.drives, & &1.id)
      assert Enum.sort(Map.keys(report.drive_energy)) == Enum.sort(page_ids)
    end

    assert hd(reports).pagination.from == 1
    assert hd(reports).pagination.to == 20
    assert List.last(reports).pagination.from == 161
    assert List.last(reports).pagination.to == 161
  end

  test "invalid and out-of-range page requests are bounded, including empty results", %{
    current_user: user,
    car: car
  } do
    insert_drives(car, 21)

    for page <- [nil, 0, -5, "bad", "2x", ["2"], %{"page" => "2"}] do
      report = Fleet.trips(user, car.id, 30, page)
      assert report.pagination.page == 1
      assert length(report.drives) == 20
    end

    for page <- [2, "2", "999999999999999999999999"] do
      report = Fleet.trips(user, car.id, 30, page)
      assert report.pagination.page == 2
      assert length(report.drives) == 1
    end

    empty = Fleet.trips(user, create_car().id, 30, 999)
    assert empty.drives == []
    assert %{page: 1, total_count: 0, total_pages: 1, from: 0, to: 0} = empty.pagination
  end

  test "page navigation keeps filters and summaries, and filter changes reset the page", %{
    conn: conn,
    car: car
  } do
    insert_drives(car, 20, DateTime.add(DateTime.utc_now(), -10, :day))
    ids = insert_drives(car, 21)
    other_car = create_car()
    [other_id] = insert_drives(other_car, 1)

    {:ok, view, _} = live(conn, "/trips?car=#{car.id}&days=90")
    assert has_element?(view, "#trip-pagination", "共 41 条")
    assert has_element?(view, "#trips-previous[aria-disabled='true']")
    assert row_count(view) == 20

    view |> element("#trips-next") |> render_click()
    assert_patch(view, "/trips?car=#{car.id}&days=90&page=2#trip-list")
    assert row_count(view) == 20
    assert has_element?(view, "#trip-pagination", "第 21–40 条")
    assert has_element?(view, "#trip-row-#{List.last(ids)}")
    assert has_element?(view, ".metric-card", "41 次")

    view |> element("#trips-last") |> render_click()
    assert_patch(view, "/trips?car=#{car.id}&days=90&page=3#trip-list")
    assert row_count(view) == 1
    assert has_element?(view, "#trips-next[aria-disabled='true']")

    view |> element(".range-picker button[phx-value-days='7']") |> render_click()
    assert_patch(view, "/trips?car=#{car.id}&days=7")
    assert has_element?(view, "#trip-pagination", "第 1–20 条，共 21 条")

    view |> element("#trips-next") |> render_click()
    assert_patch(view, "/trips?car=#{car.id}&days=7&page=2#trip-list")

    view |> form(".vehicle-picker", vehicle: %{id: other_car.id}) |> render_change()
    assert_patch(view, "/trips?car=#{other_car.id}&days=7")
    assert row_count(view) == 1
    assert has_element?(view, "#trip-row-#{other_id}")
    assert has_element?(view, "#trip-pagination", "第 1 / 1 页")
  end

  test "opening a route and returning keeps the original page and time range", %{
    conn: conn,
    car: car
  } do
    ids = insert_drives(car, 21)
    id = List.last(ids)
    path = "/trips?car=#{car.id}&days=90&page=2#trip-list"
    {:ok, view, _} = live(conn, path)

    {:ok, detail, _} =
      view |> element("#trip-row-#{id} .table-action") |> render_click() |> follow_redirect(conn)

    assert has_element?(detail, ".back-link[href='#{path}']")

    {:ok, returned, _} =
      detail |> element(".back-link") |> render_click() |> follow_redirect(conn)

    assert has_element?(returned, "#trip-row-#{id}")
    assert has_element?(returned, "#trip-pagination", "第 2 / 2 页")
    assert has_element?(returned, ".range-picker button.is-active", "90 天")
    assert row_count(returned) == 1
  end

  @tag platform_role: :member
  test "page counts, rows and energy remain scoped to the member's vehicles", %{
    conn: conn,
    current_user: user,
    car: car
  } do
    no_access = Fleet.trips(user, car.id, 30, 2)
    assert no_access.car == nil
    assert no_access.pagination.total_count == 0

    {:ok, _} = AccountFixtures.grant(user, car)
    ids = insert_drives(car, 21)
    other_car = create_car()
    insert_drives(other_car, 150)

    report = Fleet.trips(user, other_car.id, 30, 999)
    assert report.car.id == car.id
    assert report.pagination.total_count == 21
    assert report.pagination.page == 2
    assert Enum.map(report.drives, & &1.id) == [List.last(ids)]
    assert Map.keys(report.drive_energy) == [List.last(ids)]

    {:ok, view, _} = live(conn, "/trips?car=#{other_car.id}&days=30&page=999")
    assert row_count(view) == 1
    assert has_element?(view, "#trip-pagination", "共 21 条")
    first_page = "/trips?car=#{car.id}&days=30&page=1#trip-list"
    assert has_element?(view, "#trips-first[href='#{first_page}']")
  end

  test "empty lists show a clear count and no active paging links", %{conn: conn, car: car} do
    {:ok, view, _} = live(conn, "/trips?car=#{car.id}&page=2")
    assert has_element?(view, ".empty-inline", "该时间范围没有行程")
    assert has_element?(view, "#trip-pagination", "共 0 条")
    refute has_element?(view, "#trip-pagination a")
  end

  defp create_car do
    {:ok, car} =
      Log.create_car(%{
        efficiency: 0.153,
        eid: System.unique_integer([:positive]),
        vid: System.unique_integer([:positive]),
        vin: "PAGING#{System.unique_integer([:positive])}"
      })

    car
  end

  defp insert_drives(car, count, date \\ DateTime.add(DateTime.utc_now(), -3600)) do
    entries =
      for _ <- 1..count do
        %{
          car_id: car.id,
          start_date: date,
          end_date: DateTime.add(date, 60),
          distance: 1.0,
          duration_min: 1,
          start_rated_range_km: Decimal.new("300"),
          end_rated_range_km: Decimal.new("299")
        }
      end

    {^count, rows} = Repo.insert_all(Drive, entries, returning: [:id])
    rows |> Enum.map(& &1.id) |> Enum.sort(:desc)
  end

  defp row_count(view) do
    view |> render() |> Floki.parse_document!() |> Floki.find("#trip-list tbody tr") |> length()
  end
end
