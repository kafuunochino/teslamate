defmodule TeslaMateWeb.BatteryComponents do
  use Phoenix.Component
  import TeslaMateWeb.PlatformComponents
  alias TeslaMate.BatteryData

  attr :data, :map, required: true
  attr :mode, :string, default: "battery"

  def battery_panel(assigns) do
    assigns =
      assign(
        assigns,
        :groups,
        panel_groups(assigns.mode) |> Enum.map(&optional_fields(&1, assigns.data))
      )

    ~H"""
    <div class="battery-panels" id={"#{@mode}-readings"}>
      <section
        :for={group <- @groups}
        id={group[:id] && "#{@mode}-#{group.id}"}
        class="data-card battery-panel"
      >
        <div class="data-card__header">
          <div>
            <h2><i class={"mdi mdi-#{group.icon}"} aria-hidden="true"></i> <%= group.title %></h2>
            <p><%= group.hint %></p>
          </div>
        </div>
        <dl class="battery-readings">
          <.reading
            :for={{key, label, format} <- group.fields}
            id={"#{@mode}-#{key}"}
            label={label}
            format={format}
            reading={BatteryData.get(@data, key)}
          />
        </dl>
      </section>
    </div>
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

  @primary_charge_fields ~w(charging_state battery_level usable_battery_level charge_limit_soc
                            charger_power charge_energy_added time_to_full_charge charge_rate_km_h)a

  defp panel_groups("charging") do
    [main | _] = groups("charging")

    [
      %{
        main
        | fields: Enum.filter(main.fields, fn {key, _, _} -> key in @primary_charge_fields end)
      },
      temperature_group()
    ]
  end

  defp panel_groups("charging-extra") do
    [main | rest] = groups("charging")

    details = %{
      main
      | title: "电压、电流与充入续航",
        fields: Enum.reject(main.fields, fn {key, _, _} -> key in @primary_charge_fields end)
    }

    [details | rest] ++
      [telemetry_group(), drive_temperature_group(), climate_settings_group()] ++
      groups("charging-extra")
  end

  defp panel_groups(mode), do: groups(mode)

  defp groups("driving") do
    [
      %{
        title: "电池与到达预估",
        icon: "battery-heart-variant",
        hint: "电量差来自同一次采样；预热状态不代表电芯温度。",
        fields: [
          {:pack_voltage, "电池包电压", {:unit, " V", 1}},
          {:pack_current, "电池包电流", {:unit, " A", 1}},
          {:brick_voltage_delta_mv, "电芯组最大压差", {:unit, " mV", 1}},
          {:usable_battery_level, "可用电量", :percent},
          {:unavailable_level, "显示与可用电量差", :points},
          {:battery_heater_on, "电池加热器", :on_off},
          {:is_preconditioning, "车辆预热 / 预冷", :on_off},
          {:active_route_energy_at_arrival, "预计到达电量", :percent},
          {:active_route_destination, "当前导航目的地", :text}
        ]
      },
      temperature_group(),
      drive_temperature_group(),
      climate_settings_group()
    ]
  end

  defp groups("battery") do
    [
      %{
        title: "电量与续航",
        icon: "battery-high",
        hint: "电量差不是电池衰减。满电续航由同次采样归一化估算，电量低于 20% 时不计算。",
        fields: [
          {:battery_level, "显示电量", :percent},
          {:usable_battery_level, "可用电量", :percent},
          {:unavailable_level, "显示与可用电量差", :points},
          {:rated_battery_range_km, "额定续航", :distance},
          {:est_battery_range_km, "预计续航", :distance},
          {:ideal_battery_range_km, "理想续航", :distance},
          {:full_rated_range_km, "估算满电额定续航", :distance},
          {:charge_limit_soc, "充电上限", :percent}
        ]
      },
      temperature_group(),
      drive_temperature_group(),
      thermal_group(),
      climate_settings_group(),
      telemetry_group(),
      %{
        title: "充电读数",
        icon: "ev-station",
        hint: "完整参数在充电页查看。功率、电压和电流均为充电接口数据。",
        fields: [
          {:charging_state, "充电状态", :state},
          {:charger_power, "充电功率", {:unit, " kW", 1}},
          {:charge_energy_added, "会话已充入", :energy},
          {:charge_rate_km_h, "续航补充速率", {:unit, " km/h", 1}},
          {:time_to_full_charge, "距充电目标", :hours},
          {:fast_charger_present, "快充连接", :yes_no}
        ]
      }
    ]
  end

  defp groups("charging") do
    [
      %{
        title: "充电参数",
        icon: "ev-station",
        hint: "电压 / 电流为充电侧读数，并非电池包电压 / 电流。历史读数会注明采集时间。",
        fields: [
          {:charging_state, "充电状态", :state},
          {:battery_level, "显示电量", :percent},
          {:usable_battery_level, "可用电量", :percent},
          {:charge_limit_soc, "充电上限", :percent},
          {:charger_power, "充电功率", {:unit, " kW", 1}},
          {:charger_voltage, "充电侧电压", {:unit, " V", 0}},
          {:charger_actual_current, "充电侧电流", {:unit, " A", 0}},
          {:charger_phases, "充电相数", {:unit, " 相", 0}},
          {:charge_energy_added, "会话已充入", :energy},
          {:time_to_full_charge, "距充电目标", :hours},
          {:charge_rate_km_h, "续航补充速率", {:unit, " km/h", 1}},
          {:charge_range_added_rated_km, "本次增加额定续航", :distance},
          {:charge_range_added_ideal_km, "本次增加理想续航", :distance},
          {:charge_current_request, "请求充电电流", {:unit, " A", 0}},
          {:charge_current_request_max, "最大请求电流", {:unit, " A", 0}},
          {:charger_pilot_current, "充电设备允许电流", {:unit, " A", 0}}
        ]
      },
      %{
        title: "充电接口与计划",
        icon: "power-plug",
        hint: "以下均为读取车辆返回的状态；设置仍以车内或 Tesla App 为准。",
        fields: [
          {:fast_charger_present, "快充连接", :yes_no},
          {:fast_charger_brand, "快充品牌", :text},
          {:fast_charger_type, "快充类型", :text},
          {:conn_charge_cable, "充电线类型", :text},
          {:charge_port_door_open, "充电口盖", :open_closed},
          {:charge_port_latch, "充电口锁扣", :state},
          {:charge_port_cold_weather_mode, "充电口寒冷模式", :on_off},
          {:scheduled_charging_pending, "等待计划充电", :yes_no},
          {:scheduled_charging_start_time, "计划开始（北京时间）", :date},
          {:charge_limit_soc_min, "可设置的最低上限", :percent},
          {:charge_limit_soc_max, "可设置的最高上限", :percent},
          {:charge_limit_soc_std, "车辆标准充电上限", :percent}
        ]
      },
      thermal_group()
    ]
  end

  defp groups("charging-extra") do
    [
      %{
        title: "更多充电状态",
        icon: "information-outline",
        hint: "部分车型或软件版本不提供这些字段，缺失值保持为“—”。",
        fields: [
          {:charge_enable_request, "充电启用请求", :yes_no},
          {:user_charge_enable_request, "用户充电请求", :yes_no},
          {:charge_to_max_range, "最大续航充电", :on_off},
          {:trip_charging, "旅程充电标志", :on_off},
          {:max_range_charge_counter, "最大续航充电计数", {:unit, " 次", 0}},
          {:managed_charging_active, "托管充电", :on_off},
          {:managed_charging_start_time, "托管开始（北京时间）", :date},
          {:managed_charging_user_canceled, "用户取消托管充电", :yes_no}
        ]
      }
    ]
  end

  defp telemetry_group do
    %{
      title: "电池包遥测",
      icon: "battery-sync",
      hint: "来自 Fleet Telemetry。电压为电芯组极值；压差仅在同次采样时计算。温度在上方独立区域显示。",
      fields: [
        {:pack_voltage, "电池包电压", {:unit, " V", 1}},
        {:pack_current, "电池包电流", {:unit, " A", 1}},
        {:energy_remaining, "电池剩余能量", :energy},
        {:brick_voltage_max, "最高电芯组电压", {:unit, " V", 3}},
        {:brick_voltage_min, "最低电芯组电压", {:unit, " V", 3}},
        {:brick_voltage_delta_mv, "电芯组最大压差", {:unit, " mV", 1}},
        {:num_brick_voltage_max, "最高电压电芯组编号", {:unit, "", 0}},
        {:num_brick_voltage_min, "最低电压电芯组编号", {:unit, "", 0}},
        {:bms_state, "电池管理系统状态", :state},
        {:hvil, "高压互锁状态", :state},
        {:lifetime_energy_used, "累计放电能量", :energy},
        {:ac_charging_power, "交流充电输入功率", {:unit, " kW", 1}},
        {:dc_charging_power, "直流充电输入功率", {:unit, " kW", 1}},
        {:ac_charging_energy_in, "本次交流充电输入能量", :energy},
        {:dc_charging_energy_in, "本次直流充电输入能量", :energy},
        {:nominal_full_pack_energy, "标称满电能量", :energy},
        {:brick_soc_min, "最低电芯组电量", :percent},
        {:lifetime_charged_energy, "累计充入能量", :energy}
      ]
    }
  end

  defp temperature_group do
    %{
      id: "temperature",
      title: "温度监测",
      icon: "thermometer",
      hint: "单位为摄氏度。模组温度需完成数据钥匙配对后由车辆遥测上报；内外温差为车内减车外，温差只使用同次采样。",
      fields: [
        {:module_temp_max, "最高模组温度", {:unit, " °C", 1}},
        {:module_temp_min, "最低模组温度", {:unit, " °C", 1}},
        {:module_temp_delta, "模组温差", {:unit, " °C", 1}},
        {:inside_temp, "车内温度", {:unit, " °C", 1}},
        {:outside_temp, "车外温度", {:unit, " °C", 1}},
        {:cabin_temp_delta, "车内 − 车外温差", :signed_celsius},
        {:num_module_temp_max, "最高温度模组编号", {:unit, "", 0}},
        {:num_module_temp_min, "最低温度模组编号", {:unit, "", 0}}
      ]
    }
  end

  defp drive_temperature_group do
    %{
      id: "drive-temperature",
      title: "驱动系统温度",
      icon: "engine",
      hint: "来自 Fleet Telemetry。电机显示定子温度，逆变器分别显示出口和散热器温度；未搭载或未上报的读数保持为“—”。",
      fields: [
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
      ]
    }
  end

  defp climate_settings_group do
    %{
      id: "climate-settings",
      title: "空调设定温度",
      icon: "air-conditioner",
      hint: "以下为目标温度，实际车内温度在“温度监测”中显示。遥测按车辆左 / 右侧命名，不假定方向盘位置。",
      fields: [
        {:driver_temp_setting, "驾驶位设定温度", {:unit, " °C", 1}},
        {:passenger_temp_setting, "副驾驶位设定温度", {:unit, " °C", 1}},
        {:hvac_left_temp_setting, "左前设定温度（遥测）", {:unit, " °C", 1}},
        {:hvac_right_temp_setting, "右前设定温度（遥测）", {:unit, " °C", 1}},
        {:is_climate_on, "空调状态", :on_off}
      ]
    }
  end

  @extra_motor_fields ~w(rear_left_motor_temp rear_right_motor_temp rear_left_inverter_temp
                         rear_right_inverter_temp rear_left_heatsink_temp rear_right_heatsink_temp)a

  defp optional_fields(group, data) do
    fields =
      Enum.reject(group.fields, fn {key, _, _} ->
        key in @extra_motor_fields and is_nil(BatteryData.get(data, key))
      end)

    %{group | fields: fields}
  end

  defp thermal_group do
    %{
      title: "电池加热与预处理",
      icon: "thermometer",
      hint: "加热标志来自车辆接口；实际温度在“温度监测”中显示。",
      fields: [
        {:battery_heater_on, "电池加热器", :on_off},
        {:battery_heater, "气候接口电池加热标志", :on_off},
        {:battery_heater_no_power, "电池加热供电不足", :yes_no},
        {:not_enough_power_to_heat, "充电供电不足以加热", :yes_no},
        {:is_preconditioning, "车辆预热 / 预冷", :on_off},
        {:smart_preconditioning, "智能预处理", :on_off}
      ]
    }
  end

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
