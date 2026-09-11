defmodule TeslaMateWeb.BatteryComponents do
  use Phoenix.LiveComponent
  import TeslaMateWeb.PlatformComponents
  alias TeslaMate.BatteryData

  attr :data, :map, required: true
  attr :mode, :string, default: "battery"

  def battery_panel(assigns) do
    ~H"""
    <.live_component module={__MODULE__} id={"#{@mode}-panel"} data={@data} mode={@mode} />
    """
  end

  @impl true
  def update(assigns, socket) do
    {normal, advanced} = split_groups(groups(assigns.mode, assigns.data), assigns.data)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(normal: normal, advanced: advanced)
     |> assign_new(:expanded, fn -> false end)}
  end

  @impl true
  def handle_event("toggle_details", _, socket) do
    {:noreply, assign(socket, :expanded, not socket.assigns.expanded)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="battery-panels" id={"#{@mode}-readings"}>
      <.reading_group :for={group <- @normal} group={group} mode={@mode} data={@data} />
      <section :if={@advanced != []} class="battery-extra">
        <button
          id={"#{@mode}-advanced-toggle"}
          type="button"
          class="battery-details-toggle"
          phx-click="toggle_details"
          phx-target={@myself}
          aria-expanded={to_string(@expanded)}
          aria-controls={"#{@mode}-advanced"}
        >
          <i class={"mdi mdi-chevron-#{if @expanded, do: "up", else: "down"}"} aria-hidden="true"></i>
          高级数据与未上报项目
        </button>
        <div :if={@expanded} id={"#{@mode}-advanced"} class="battery-panels battery-details-content">
          <.reading_group :for={group <- @advanced} group={group} mode={@mode} data={@data} />
        </div>
      </section>
    </div>
    """
  end

  attr :group, :map, required: true
  attr :mode, :string, required: true
  attr :data, :map, required: true

  defp reading_group(assigns) do
    ~H"""
    <section id={"#{@mode}-#{@group.id}"} class="data-card battery-panel">
      <div class="data-card__header">
        <div>
          <h2><i class={"mdi mdi-#{@group.icon}"} aria-hidden="true"></i> <%= @group.title %></h2>
          <p><%= @group.hint %></p>
        </div>
      </div>
      <dl class="battery-readings">
        <.reading
          :for={{key, label, format} <- @group.fields}
          id={"#{@mode}-#{key}"}
          label={label}
          format={format}
          reading={BatteryData.get(@data, key)}
        />
      </dl>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :format, :any, required: true
  attr :reading, :any, default: nil

  def reading(assigns) do
    ~H"""
    <div id={@id} class="battery-reading">
      <dt><%= @label %></dt>
      <dd><%= display(@reading && @reading.value, @format) %></dd>
      <small :if={@reading} class={if @reading.fresh?, do: "is-current", else: "is-recorded"}>
        <%= if @reading.source == :telemetry, do: "遥测 · " %><%= if @reading.fresh?,
          do: "采集于",
          else: "最近记录" %>
        <time><%= date_time(@reading.measured_at) %></time>
      </small>
      <small :if={@reading && is_nil(@reading.value)}>车辆上报无效读数</small>
      <small :if={!@reading}>车辆尚未上报</small>
    </div>
    """
  end

  # Each signal has one owning page. Valid ordinary readings stay visible;
  # diagnostics and unavailable optional signals remain in the expandable area.
  defp split_groups(groups, data) do
    Enum.reduce(groups, {[], []}, fn group, {normal, advanced} ->
      if group.advanced do
        {normal, advanced ++ [group]}
      else
        {available, missing} =
          Enum.split_with(group.fields, fn {key, _, _} ->
            group.required or match?(%{value: value} when not is_nil(value), data[key])
          end)

        normal = if available == [], do: normal, else: normal ++ [%{group | fields: available}]

        advanced =
          if missing == [],
            do: advanced,
            else:
              advanced ++
                [
                  %{
                    group
                    | id: group.id <> "-unavailable",
                      title: group.title <> " · 待上报",
                      fields: missing
                  }
                ]

        {normal, advanced}
      end
    end)
  end

  defp group(id, title, icon, hint, fields, opts \\ []) do
    %{
      id: id,
      title: title,
      icon: icon,
      hint: hint,
      fields: fields,
      advanced: Keyword.get(opts, :advanced, false),
      required: Keyword.get(opts, :required, false)
    }
  end

  defp groups("battery", _data) do
    [
      group(
        "state",
        "电量与续航",
        "battery-high",
        "电量差不代表电池衰减；估算满电续航只使用同次采样且电量不低于 20%。",
        [
          {:battery_level, "显示电量", :percent},
          {:usable_battery_level, "可用电量", :percent},
          {:unavailable_level, "显示与可用电量差", :points},
          {:rated_battery_range_km, "额定续航", :distance},
          {:est_battery_range_km, "预计续航", :distance},
          {:ideal_battery_range_km, "理想续航", :distance},
          {:full_rated_range_km, "估算满电额定续航", :distance}
        ],
        required: true
      ),
      group("pack", "电池包状态", "car-battery", "车辆直接上报的电池侧读数，最近记录保留原始采集时间。", [
        {:energy_remaining, "电池剩余能量", :energy},
        {:pack_voltage, "电池包电压", {:unit, " V", 1}},
        {:pack_current, "电池包电流", {:unit, " A", 1}},
        {:nominal_full_pack_energy, "标称满电能量", :energy},
        {:battery_heater_on, "电池加热器", :on_off}
      ]),
      group("temperature", "电池模组温度", "thermometer", "温差仅使用同次采样的最高、最低模组温度。", [
        {:module_temp_max, "最高模组温度", {:unit, " °C", 1}},
        {:module_temp_min, "最低模组温度", {:unit, " °C", 1}},
        {:module_temp_delta, "模组温差", {:unit, " °C", 1}}
      ]),
      group(
        "diagnostics",
        "电池诊断数据",
        "battery-sync",
        "电芯组极值与编号不是全部电芯明细；未知值不作为零参与计算。",
        [
          {:brick_voltage_max, "最高电芯组电压", {:unit, " V", 3}},
          {:brick_voltage_min, "最低电芯组电压", {:unit, " V", 3}},
          {:brick_voltage_delta_mv, "电芯组最大压差", {:unit, " mV", 1}},
          {:num_brick_voltage_max, "最高电压电芯组编号", {:unit, "", 0}},
          {:num_brick_voltage_min, "最低电压电芯组编号", {:unit, "", 0}},
          {:num_module_temp_max, "最高温度模组编号", {:unit, "", 0}},
          {:num_module_temp_min, "最低温度模组编号", {:unit, "", 0}},
          {:bms_state, "电池管理系统状态", :state},
          {:hvil, "高压互锁状态", :state},
          {:lifetime_energy_used, "累计放电能量", :energy},
          {:lifetime_charged_energy, "累计充入能量", :energy},
          {:brick_soc_min, "最低电芯组电量", :percent},
          {:battery_heater_no_power, "电池加热供电不足", :yes_no},
          {:not_enough_power_to_heat, "供电不足以加热", :yes_no}
        ],
        advanced: true
      )
    ]
  end

  defp groups("driving", data) do
    setpoints =
      if match?(%{value: a} when is_number(a), data[:hvac_left_temp_setting]) and
           match?(%{value: b} when is_number(b), data[:hvac_right_temp_setting]) do
        [
          {:hvac_left_temp_setting, "左前目标温度", {:unit, " °C", 1}},
          {:hvac_right_temp_setting, "右前目标温度", {:unit, " °C", 1}}
        ]
      else
        [
          {:driver_temp_setting, "驾驶位目标温度", {:unit, " °C", 1}},
          {:passenger_temp_setting, "副驾驶位目标温度", {:unit, " °C", 1}}
        ]
      end

    [
      group("navigation", "导航到达预估", "navigation", "读取车辆当前导航；未开启导航时显示在待上报项目中。", [
        {:active_route_energy_at_arrival, "预计到达电量", :percent},
        {:active_route_destination, "当前导航目的地", :text}
      ]),
      group("drive-temperature", "驱动系统温度", "engine", "电机定子与逆变器温度，单位为摄氏度。车辆未提供的读数可在高级数据中查看。", [
        {:front_motor_temp, "前电机定子温度", {:unit, " °C", 1}},
        {:rear_motor_temp, "后电机定子温度", {:unit, " °C", 1}},
        {:front_inverter_temp, "前逆变器出口温度", {:unit, " °C", 1}},
        {:rear_inverter_temp, "后逆变器出口温度", {:unit, " °C", 1}},
        {:front_heatsink_temp, "前逆变器散热器温度", {:unit, " °C", 1}},
        {:rear_heatsink_temp, "后逆变器散热器温度", {:unit, " °C", 1}},
        {:rear_left_motor_temp, "左后电机定子温度", {:unit, " °C", 1}},
        {:rear_right_motor_temp, "右后电机定子温度", {:unit, " °C", 1}},
        {:rear_left_inverter_temp, "左后逆变器出口温度", {:unit, " °C", 1}},
        {:rear_right_inverter_temp, "右后逆变器出口温度", {:unit, " °C", 1}},
        {:rear_left_heatsink_temp, "左后逆变器散热器温度", {:unit, " °C", 1}},
        {:rear_right_heatsink_temp, "右后逆变器散热器温度", {:unit, " °C", 1}}
      ]),
      group(
        "climate",
        "座舱与空调",
        "air-conditioner",
        "实际温度与目标温度分开标明。遥测按车辆左 / 右侧命名，不假定方向盘位置。",
        [
          {:inside_temp, "车内实际温度", {:unit, " °C", 1}},
          {:outside_temp, "车外温度", {:unit, " °C", 1}},
          {:cabin_temp_delta, "车内 − 车外温差", :signed_celsius}
        ] ++
          setpoints ++
          [
            {:is_climate_on, "空调状态", :on_off},
            {:is_preconditioning, "车辆预热 / 预冷", :on_off}
          ]
      ),
      group(
        "climate-diagnostics",
        "座舱高级状态",
        "information-outline",
        "只展示车辆返回的状态，目标设置以车内或 Tesla App 为准。",
        [
          {:smart_preconditioning, "智能预处理", :on_off}
        ],
        advanced: true
      )
    ]
  end

  defp groups("charging", data) do
    battery_energy =
      if preferred_reading?(data[:dc_charging_energy_in], data[:charge_energy_added]),
        do: {:dc_charging_energy_in, "本次电池侧充入能量（AC / DC）", :energy},
        else: {:charge_energy_added, "本次电池侧充入能量", :energy}

    [
      group(
        "session",
        "本次充电",
        "ev-station",
        "充电器侧与电池侧分开显示，DCChargingEnergyIn 同时适用于交流和直流充电。",
        [
          {:charging_state, "充电状态", :state},
          {:charge_limit_soc, "充电上限", :percent},
          {:charger_power, "充电功率", {:unit, " kW", 1}},
          {:time_to_full_charge, "距充电目标", :hours},
          {:charge_rate_km_h, "续航补充速率", {:unit, " km/h", 1}}
        ],
        required: true
      ),
      group(
        "electrical",
        "充电能量与电气参数",
        "lightning-bolt",
        "这里的电压、电流为充电侧读数，并非电池包电压、电流。交流输入读数不用于直流充电。",
        [
          battery_energy,
          {:ac_charging_energy_in, "本次交流输入能量", :energy},
          {:ac_charging_power, "交流输入功率", {:unit, " kW", 1}},
          {:dc_charging_power, "直流充电功率", {:unit, " kW", 1}},
          {:charger_voltage, "充电侧电压", {:unit, " V", 0}},
          {:charger_actual_current, "充电侧电流", {:unit, " A", 0}},
          {:charger_phases, "充电相数", {:unit, " 相", 0}}
        ]
      ),
      group(
        "interface",
        "充电接口与计划",
        "power-plug",
        "以下均为车辆返回的状态，设置仍以车内或 Tesla App 为准。",
        [
          {:fast_charger_present, "快充连接", :yes_no},
          {:fast_charger_brand, "快充品牌", :text},
          {:fast_charger_type, "快充类型", :text},
          {:conn_charge_cable, "充电线类型", :text},
          {:charge_port_door_open, "充电口盖", :open_closed},
          {:charge_port_latch, "充电口锁扣", :state},
          {:charge_port_cold_weather_mode, "充电口寒冷模式", :on_off},
          {:scheduled_charging_pending, "等待计划充电", :yes_no},
          {:scheduled_charging_start_time, "计划开始（北京时间）", :date},
          {:charge_current_request, "请求充电电流", {:unit, " A", 0}},
          {:charge_current_request_max, "最大请求电流", {:unit, " A", 0}},
          {:charger_pilot_current, "充电设备允许电流", {:unit, " A", 0}},
          {:charge_limit_soc_min, "可设置的最低上限", :percent},
          {:charge_limit_soc_max, "可设置的最高上限", :percent},
          {:charge_limit_soc_std, "车辆标准充电上限", :percent},
          {:charge_range_added_rated_km, "本次增加额定续航", :distance},
          {:charge_range_added_ideal_km, "本次增加理想续航", :distance}
        ],
        advanced: true
      ),
      group(
        "flags",
        "更多充电状态",
        "information-outline",
        "部分车型或软件版本不提供这些字段，缺失值保持为“—”。",
        [
          {:charge_enable_request, "充电启用请求", :yes_no},
          {:user_charge_enable_request, "用户充电请求", :yes_no},
          {:charge_to_max_range, "最大续航充电", :on_off},
          {:trip_charging, "旅程充电标志", :on_off},
          {:max_range_charge_counter, "最大续航充电计数", {:unit, " 次", 0}},
          {:managed_charging_active, "托管充电", :on_off},
          {:managed_charging_start_time, "托管开始（北京时间）", :date},
          {:managed_charging_user_canceled, "用户取消托管充电", :yes_no}
        ],
        advanced: true
      )
    ]
  end

  defp preferred_reading?(%{value: value, measured_at: date}, other) when is_number(value) do
    is_nil(other) or is_nil(other.measured_at) or DateTime.compare(date, other.measured_at) != :lt
  end

  defp preferred_reading?(_, _), do: false

  defp display(nil, _format), do: "—"

  defp display(value, :signed_celsius) when is_number(value),
    do: if(value > 0, do: "+", else: "") <> format_number(value, 1) <> " °C"

  defp display(value, :percent), do: percentage(value)
  defp display(value, :points), do: format_number(value, 1) <> " 个百分点"
  defp display(value, :distance), do: distance(value)
  defp display(value, :energy), do: energy(value, 2)
  defp display(value, :date), do: date_time(value)
  defp display(value, :hours) when is_number(value) and value >= 0, do: duration(value * 60)
  defp display(value, {:unit, unit, precision}), do: format_number(value, precision) <> unit
  defp display(true, :on_off), do: "开启"
  defp display(false, :on_off), do: "关闭"
  defp display(true, :yes_no), do: "是"
  defp display(false, :yes_no), do: "否"
  defp display(true, :open_closed), do: "打开"
  defp display(false, :open_closed), do: "关闭"
  defp display("BMSStateStandby", :state), do: "待机"
  defp display("BMSStateDrive", :state), do: "行驶"
  defp display("BMSStateSupport", :state), do: "辅助供电"
  defp display("BMSStateCharge", :state), do: "充电"
  defp display("BMSStateFault", :state), do: "故障状态"
  defp display("HvilStatusOK", :state), do: "正常"
  defp display("HvilStatusFault", :state), do: "故障状态"
  defp display("Charging", :state), do: "充电中"
  defp display("Complete", :state), do: "已完成"
  defp display("Stopped", :state), do: "已停止"
  defp display("Disconnected", :state), do: "未连接"
  defp display("Starting", :state), do: "准备充电"
  defp display("NoPower", :state), do: "无供电"
  defp display("Engaged", :state), do: "已锁止"
  defp display("Disengaged", :state), do: "已解锁"
  defp display("Blocking", :state), do: "锁扣受阻"
  defp display(value, format) when is_binary(value) and format in [:text, :state], do: value
  defp display(_, _), do: "—"
end
