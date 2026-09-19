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

  def document(page, stylesheet \\ "/assets/app.css") when page in ["home", "trips", "charging"] do
    assigns = %{
      __changed__: nil,
      page: page,
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
