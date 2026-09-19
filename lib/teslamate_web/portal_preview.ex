defmodule TeslaMateWeb.PortalPreview do
  @moduledoc """
  Read-only previews of the real dashboard templates, backed only by constants.
  Never mount a LiveView, query Fleet/Repo, or subscribe to vehicle updates here.
  """
  use Phoenix.Component
  import TeslaMateWeb.PlatformComponents

  alias TeslaMate.Log.Car
  alias TeslaMate.Locations.GeoFence
  alias TeslaMateWeb.DashboardLive

  attr :page, :string, required: true
  attr :title, :string, required: true
  attr :class, :string, default: ""

  def preview(assigns) do
    ~H"""
    <figure class={["portal-demo portal-ui-demo", @class]}>
      <div class="portal-demo-toolbar">
        <span><i class="mdi mdi-monitor-dashboard" aria-hidden="true"></i> <%= @title %></span>
        <span class="portal-demo-badge">实际界面 · 虚拟数据</span>
      </div>
      <div class="portal-preview-stage">
        <iframe
          src={"/preview/#{@page}"}
          title={"#{@title}，真实组件与虚拟数据的只读示例"}
          class="portal-preview-screen"
          width="1440"
          height="1100"
          sandbox="allow-same-origin"
          tabindex="-1"
          inert
          loading="lazy"
        >
        </iframe>
        <button
          type="button"
          class="portal-preview-open"
          data-preview-page={@page}
          data-preview-title={@title}
          aria-haspopup="dialog"
          aria-label={"放大查看#{@title}实际界面"}
        >
          <span><i class="mdi mdi-arrow-expand-all" aria-hidden="true"></i> 放大查看实际界面</span>
        </button>
      </div>
      <figcaption>虚拟数据演示 · 非真实地图、地点或车辆记录</figcaption>
    </figure>
    """
  end

  def document(page, stylesheet \\ "/assets/app.css")
      when page in ["home", "trips", "trip", "charging"] do
    assigns = %{
      __changed__: nil,
      page: if(page == "trip", do: "trips", else: page),
      stylesheet: stylesheet,
      content: content(page),
      navigation: [
        {"home", "view-dashboard-outline", "首页"},
        {"driving", "gauge", "行车仪表盘"},
        {"trips", "map-marker-path", "行程轨迹"},
        {"battery", "car-battery", "电池"},
        {"charging", "ev-station", "充电"},
        {"analysis", "chart-box-outline", "分析"},
        {"vehicles", "car-key", "车辆中心"},
        {"tesla-account", "cloud-key-outline", "Tesla 连接"},
        {"geo-fences", "map-marker-radius", "地理围栏"}
      ]
    }

    ~H"""
    <!DOCTYPE html>
    <html lang="zh-Hans" data-theme="light">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex, nofollow" />
        <title>特友会 · 虚拟数据界面示例</title>
        <link rel="stylesheet" href={@stylesheet} />
      </head>
      <body class="platform-body portal-sample-body" inert>
        <div class="platform-shell">
          <aside id="platform-sidebar" class="platform-sidebar" aria-label="示例主菜单">
            <div class="sidebar-brand">
              <a>
                <span><i class="mdi mdi-car-connected"></i></span>
                <div><strong>特友会</strong><small>车辆数据中心</small></div>
              </a>
            </div>
            <nav class="sidebar-nav">
              <p>车辆数据</p>
              <a :for={{key, icon, label} <- @navigation} class={if key == @page, do: "is-active"}>
                <i class={"mdi mdi-#{icon}"}></i><span><%= label %></span>
              </a>
            </nav>
            <div class="sidebar-account">
              <div class="account-avatar">演</div>
              <div><strong>演示用户</strong><small>普通用户</small></div>
              <i class="mdi mdi-account-cog-outline"></i>
            </div>
          </aside>
          <div class="platform-main">
            <header class="mobile-topbar platform-topbar">
              <button id="sidebar-open" type="button" aria-label="示例菜单">
                <i class="mdi mdi-menu"></i>
              </button>
              <strong>特友会</strong>
              <div class="topbar-actions">
                <TeslaMateWeb.LayoutView.theme_controls />
                <a class="topbar-account" aria-label="示例账号设置">
                  <i class="mdi mdi-account-circle-outline"></i>
                </a>
              </div>
            </header>
            <main class="platform-content">
              <p class="portal-sample-notice">虚拟数据演示 · 全部为虚构车辆、地点及记录</p>
              <%= @content %>
            </main>
            <footer class="platform-footer footer">北京时间（UTC+8） · 虚拟数据演示</footer>
          </div>
        </div>
      </body>
    </html>
    """
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp content("home"), do: DashboardLive.Home.render(%{base_assigns() | report: home()})
  defp content("trips"), do: DashboardLive.Trips.render(%{base_assigns() | report: trips()})

  defp content("trip") do
    report = trip()

    base_assigns()
    |> Map.merge(%{
      report: report,
      map_points: Jason.encode!(report.positions),
      map_preview: route_map(%{__changed__: nil})
    })
    |> DashboardLive.Trip.render()
  end

  defp content("charging") do
    assigns = %{__changed__: nil, report: charging()}

    ~H"""
    <div class="platform-page">
      <header class="page-heading">
        <div>
          <p class="page-kicker">补能与成本</p>
          <h1>充电</h1>
          <p>充电会话、能量、成本与常用站点统一管理。</p>
        </div>
        <.vehicle_picker cars={@report.cars} current_car={@report.car} />
      </header>
      <TeslaMateWeb.ChargingHistory.history report={@report} />
    </div>
    """
  end

  defp base_assigns do
    %{
      __changed__: nil,
      report: nil,
      current_user: nil,
      # Only route helpers consume this assign; a bare connection keeps static
      # rendering independent of a running endpoint or LiveView socket.
      socket: %Plug.Conn{}
    }
  end

  defp car, do: %Car{id: 0, name: "Model Y · 示例车辆", vin: "DEMO0000000000000"}
  defp place(name), do: %GeoFence{name: name <> " · 示例"}
  defp time, do: ~U[2026-09-18 09:30:00Z]

  defp home do
    %{
      car: car(),
      cars: [car()],
      live: nil,
      state: %{state: :online},
      update: %{version: "2026.26"},
      position: %{
        date: time(),
        battery_level: 72,
        rated_battery_range_km: 356.8,
        odometer: 12860.5,
        elevation: 386,
        outside_temp: 23.5,
        latitude: 0.0,
        longitude: 0.0
      },
      location: place("湖畔公园"),
      drive_stats: %{count: 38, distance: 1286.4, duration_min: 1548},
      charge_stats: %{count: 7, energy_added: 186.4, cost: 158.44},
      recent_drives: Enum.take(drives(), 2),
      recent_drive_energy: drive_energy(),
      recent_charges: Enum.take(sessions(), 2)
    }
  end

  defp trips do
    %{
      car: car(),
      cars: [car()],
      days: 30,
      stats: %{
        count: 38,
        distance: 1286.4,
        duration_min: 1548,
        average_distance: 33.85,
        max_speed: 98
      },
      daily_distance:
        bars([26.8, 38.4, 0, 42.6, 64.8, 28.5, 96.2, 54.6, 33.8, 0, 48.2, 82.5, 36.1, 62.8]),
      drives: drives(),
      drive_energy: drive_energy(),
      destinations: [
        %{label: "创意园 · 示例", distance: 486.2, count: 16},
        %{label: "湖畔公园 · 示例", distance: 288.4, count: 8},
        %{label: "山间观景台 · 示例", distance: 192.6, count: 3}
      ]
    }
  end

  defp drives do
    Enum.map(
      [
        {1, "湖畔公园", "山间观景台", 42.6, 48, 386, 145},
        {2, "示例住宅", "创意园", 28.4, 36, 52, 67},
        {3, "创意园", "湖畔公园", 18.8, 25, 36, 48},
        {4, "示例住宅", "城市展览馆", 35.2, 42, 86, 94}
      ],
      fn {id, start, destination, km, minutes, ascent, descent} ->
        %{
          id: id,
          start_geofence: place(start),
          end_geofence: place(destination),
          start_address: nil,
          end_address: nil,
          start_date: DateTime.add(time(), -(id - 1) * 86400),
          distance: km,
          duration_min: minutes,
          speed_max: 78 + id * 4,
          ascent: ascent,
          descent: descent
        }
      end
    )
  end

  defp trip do
    drive =
      hd(drives())
      |> Map.merge(%{
        car_id: 0,
        end_date: DateTime.add(time(), 48 * 60),
        outside_temp_avg: 23.5,
        start_km: 12817.9,
        end_km: 12860.5,
        start_rated_range_km: 399.4,
        end_rated_range_km: 356.8,
        power_max: 96,
        power_min: -42
      })

    energy =
      drive_energy()[1]
      |> Map.merge(%{
        start_sample_at: drive.start_date,
        end_sample_at: drive.end_date,
        start_energy: 41.82,
        end_energy: 35.6,
        start_offset_seconds: 0,
        end_offset_seconds: 0
      })

    positions =
      route_points()
      |> Enum.with_index()
      |> Enum.map(fn {{x, y}, index} ->
        %{longitude: x / 10000, latitude: y / 10000, date: DateTime.add(time(), div(index * 48 * 60, length(route_points()) - 1))}
      end)

    %{drive: drive, energy: energy, positions: positions}
  end

  # These are illustration-space coordinates, not a recorded GPS track.
  defp route_points do
    [{120, 440}, {220, 440}, {270, 410}, {270, 310}, {375, 310}, {455, 260},
     {530, 260}, {580, 200}, {650, 200}, {705, 145}, {795, 145}, {850, 100}]
  end

  defp route_map(assigns) do
    points = Enum.map_join(route_points(), " ", fn {x, y} -> "#{x},#{y}" end)
    assigns = assign(assigns, :points, points)

    ~H"""
    <svg
      class="portal-route-map"
      viewBox="0 0 1000 560"
      role="img"
      aria-label="虚拟行程地图：从湖畔公园经过示例道路，到达山间观景台"
    >
      <rect width="1000" height="560" class="sample-map-ground" />
      <path class="sample-map-park" d="M0 315 190 330 210 510 110 560H0Z" />
      <path class="sample-map-park" d="M685 0 650 80 735 115 855 70 940 140 1000 110V0Z" />
      <path class="sample-map-water" d="M0 210Q160 150 305 190T560 125 815 265 1000 235V305Q850 325 725 250T565 190 290 250 0 280Z" />
      <g class="sample-map-blocks">
        <rect x="75" y="50" width="98" height="70" rx="12" />
        <rect x="210" y="45" width="125" height="86" rx="12" />
        <rect x="378" y="45" width="100" height="90" rx="12" />
        <rect x="322" y="365" width="95" height="128" rx="12" />
        <rect x="473" y="355" width="130" height="110" rx="12" />
        <rect x="651" y="353" width="127" height="140" rx="12" />
        <rect x="834" y="362" width="98" height="128" rx="12" />
      </g>
      <g class="sample-map-road-edge">
        <path d="M0 155H510L670 40M50 0V155M195 0V165M365 0V175M0 515H1000M455 560V330L375 310M625 560V290M805 560V320L915 210V0M0 375H260M575 0V180" />
        <polyline points={@points} />
      </g>
      <g class="sample-map-roads">
        <path d="M0 155H510L670 40M50 0V155M195 0V165M365 0V175M0 515H1000M455 560V330L375 310M625 560V290M805 560V320L915 210V0M0 375H260M575 0V180" />
        <polyline points={@points} />
      </g>
      <g class="sample-map-labels">
        <text x="82" y="360">湖畔公园</text>
        <text x="360" y="535">环湖路 · 示例</text>
        <text x="663" y="398">创意园区</text>
        <text x="777" y="47">山间绿地</text>
      </g>
      <polyline class="sample-map-route-halo" points={@points} />
      <polyline class="sample-map-route" points={@points} />
      <g class="sample-map-directions">
        <path d="m245 417 10-7-10-7M485 253l10 7-10 7M744 138l10 7-10 7" />
      </g>
      <circle cx="120" cy="440" r="17" class="sample-map-start" />
      <circle cx="850" cy="100" r="17" class="sample-map-end" />
      <g class="sample-map-markers"><text x="120" y="446">起</text><text x="850" y="106">终</text></g>
      <g class="sample-map-bubble">
        <rect x="40" y="462" width="178" height="33" rx="9" />
        <text x="129" y="484">湖畔公园 · 出发</text>
        <rect x="724" y="174" width="230" height="33" rx="9" />
        <text x="839" y="196">山间观景台 · 到达</text>
      </g>
      <g class="sample-map-legend">
        <rect x="23" y="20" width="254" height="35" rx="10" />
        <text x="150" y="43">虚拟路线演示 · 非真实道路</text>
      </g>
    </svg>
    """
  end

  defp drive_energy do
    Map.new(
      [{1, 6.22, 146.0}, {2, 4.18, 147.2}, {3, 2.96, 157.4}, {4, 5.35, 152.0}],
      fn {id, kwh, consumption} ->
        {id, %{source: :fleet_battery, energy_kwh: kwh, consumption_wh_km: consumption}}
      end
    )
  end

  defp charging do
    %{
      car: car(),
      cars: [car()],
      days: 30,
      stats: %{
        count: 7,
        energy_added: 186.4,
        energy_used: 198.2,
        cost: 158.44,
        priced_energy_added: 186.4,
        cost_count: 7,
        official_count: 7,
        input_count: 7,
        input_estimate_count: 0,
        duration_min: 1632,
        loss_kwh: 11.8,
        loss_count: 7
      },
      daily_energy: bars([28.6, 0, 25.2, 0, 22.4, 0, 0, 31.8, 0, 26.1, 0, 24.8, 0, 27.5]),
      sessions: sessions(),
      stations: [
        %{label: "示例家用充电桩", count: 5, energy: 132.6, cost: 78.24, cost_count: 5},
        %{label: "示例公共充电站", count: 2, energy: 53.8, cost: 80.2, cost_count: 2}
      ]
    }
  end

  defp sessions do
    Enum.map(
      [{1, 28.6, 30.2, 16.87}, {2, 25.2, 26.9, 37.8}, {3, 22.4, 23.8, 13.22}],
      fn {id, added, used, cost} ->
        %{
          id: id,
          start_date: DateTime.add(time(), -id * 86400),
          end_date: time(),
          geofence: place(if(id == 2, do: "公共充电站", else: "家用充电桩")),
          address: nil,
          start_battery_level: 32,
          end_battery_level: 80,
          charge_energy_added: added,
          charge_energy_used: used,
          duration_min: 240,
          cost: cost,
          energy: %{
            battery_source: :fleet_battery,
            input_source: :fleet_ac,
            loss_kwh: used - added,
            loss_percent: (used - added) / used * 100
          }
        }
      end
    )
  end

  defp bars(values) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      %{period: Date.add(~D[2026-09-01], index), value: value}
    end)
  end
end
