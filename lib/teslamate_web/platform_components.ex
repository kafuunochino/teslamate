defmodule TeslaMateWeb.PlatformComponents do
  use Phoenix.Component

  alias TeslaMate.Fleet

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil
  attr :icon, :string, default: "chart-box-outline"
  attr :tone, :string, default: "blue"

  def metric_card(assigns) do
    ~H"""
    <article class={"metric-card metric-card--#{@tone}"}>
      <div class="metric-card__icon" aria-hidden="true"><i class={"mdi mdi-#{@icon}"}></i></div>
      <div class="metric-card__body">
        <p class="metric-card__label"><%= @title %></p>
        <p class="metric-card__value"><%= @value %></p>
        <p :if={@hint} class="metric-card__hint"><%= @hint %></p>
      </div>
    </article>
    """
  end

  attr :cars, :list, required: true
  attr :current_car, :any, default: nil

  def vehicle_picker(assigns) do
    ~H"""
    <form class="vehicle-picker" phx-change="select_vehicle">
      <label for="vehicle-picker-id">当前车辆</label>
      <div class="select is-fullwidth">
        <select id="vehicle-picker-id" name="vehicle[id]" aria-label="选择车辆">
          <option
            :for={car <- @cars}
            value={car.id}
            selected={@current_car && car.id == @current_car.id}
          >
            <%= Fleet.vehicle_label(car) %> · VIN <%= Fleet.vin_suffix(car) %>
          </option>
        </select>
      </div>
    </form>
    """
  end

  attr :days, :integer, required: true

  def range_picker(assigns) do
    ~H"""
    <div class="range-picker" role="group" aria-label="统计时间范围">
      <button
        :for={{label, value} <- [{"7 天", 7}, {"30 天", 30}, {"90 天", 90}, {"1 年", 365}]}
        type="button"
        class={if @days == value, do: "is-active", else: nil}
        phx-click="select_range"
        phx-value-days={value}
      >
        <%= label %>
      </button>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :unit, :string, default: ""
  attr :empty, :string, default: "当前时间范围暂无数据"

  def bar_chart(assigns) do
    values = Enum.map(assigns.rows, &number(Map.get(&1, :value)))
    maximum = Enum.max([0.0 | values])
    assigns = assign(assigns, maximum: maximum)

    ~H"""
    <section class="data-card chart-card">
      <div class="data-card__header">
        <h2><%= @title %></h2>
      </div>
      <div :if={@rows == []} class="empty-inline"><%= @empty %></div>
      <div :if={@rows != []} class="bar-chart" role="img" aria-label={@title}>
        <div
          :for={row <- @rows}
          class="bar-chart__column"
          title={"#{format_period(row.period)}：#{format_number(row.value, 1)}#{@unit}"}
        >
          <span class="bar-chart__bar" style={"height: #{bar_height(row.value, @maximum)}%"}></span>
          <small><%= compact_period(row.period) %></small>
        </div>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, default: nil
  attr :hint, :string, default: nil

  def score_card(assigns) do
    value = assigns.value || 0
    assigns = assign(assigns, safe_value: value)

    ~H"""
    <article class="score-card">
      <div class="score-ring" style={"--score: #{@safe_value}"}>
        <strong><%= @value || "—" %></strong><span :if={@value}>分</span>
      </div>
      <div>
        <h3><%= @label %></h3>
        <p :if={@hint}><%= @hint %></p>
      </div>
    </article>
    """
  end

  attr :admin, :boolean, default: false

  def no_vehicle(assigns) do
    ~H"""
    <section class="empty-state">
      <div class="empty-state__icon"><i class="mdi mdi-car-key"></i></div>
      <h2>尚未绑定车辆</h2>
      <p :if={!@admin}>请输入管理员发放的一次性车辆认领码。仅凭 VIN 无法绑定车辆。</p>
      <p :if={@admin}>采集器还没有发现车辆，请先在“系统管理”中连接 Tesla 账号。</p>
      <.link navigate="/vehicles" class="button is-primary">前往车辆中心</.link>
    </section>
    """
  end

  def format_number(nil, _precision), do: "—"

  def format_number(%Decimal{} = value, precision),
    do: value |> Decimal.to_float() |> format_number(precision)

  def format_number(value, precision) when is_integer(value),
    do: format_number(value * 1.0, precision)

  def format_number(value, precision) when is_float(value) do
    :erlang.float_to_binary(value, decimals: precision)
  end

  def format_number(_, _), do: "—"

  def distance(value), do: unit(value, 1, " km")
  def energy(value), do: unit(value, 1, " kWh")
  def money(value), do: if(value in [nil, ""], do: "—", else: "¥#{format_number(value, 2)}")
  def percentage(value), do: unit(value, 1, "%")
  def temperature(value), do: unit(value, 1, " °C")
  def pressure(value), do: unit(value, 2, " bar")

  def ratio_percentage(nil), do: "—"
  def ratio_percentage(value), do: percentage(number(value) * 100)

  def divide(_numerator, denominator) when denominator in [nil, 0, 0.0], do: nil

  def divide(numerator, denominator) do
    denominator = number(denominator)
    if denominator > 0, do: number(numerator) / denominator, else: nil
  end

  def duration(nil), do: "—"

  def duration(minutes) do
    total = round(number(minutes))
    hours = div(total, 60)
    rest = rem(total, 60)

    cond do
      hours > 0 and rest > 0 -> "#{hours} 小时 #{rest} 分"
      hours > 0 -> "#{hours} 小时"
      true -> "#{rest} 分钟"
    end
  end

  def date_time(nil), do: "—"

  def date_time(%DateTime{} = value) do
    Calendar.strftime(value, "%Y-%m-%d %H:%M")
  end

  def date_time(%NaiveDateTime{} = value) do
    Calendar.strftime(value, "%Y-%m-%d %H:%M")
  end

  def state_label(nil), do: "未知"
  def state_label(%{state: state}), do: state_label(state)
  def state_label(:online), do: "在线"
  def state_label(:offline), do: "离线"
  def state_label(:asleep), do: "休眠"
  def state_label(:driving), do: "行驶中"
  def state_label(:charging), do: "充电中"
  def state_label(:updating), do: "更新中"
  def state_label(:suspended), do: "准备休眠"
  def state_label(:unavailable), do: "暂不可用"
  def state_label(value) when is_binary(value), do: value
  def state_label(_), do: "未知"

  def claim_status(%{claimed_at: claimed_at}) when not is_nil(claimed_at), do: "已使用"
  def claim_status(%{revoked_at: revoked_at}) when not is_nil(revoked_at), do: "已撤销"

  def claim_status(%{expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt, do: "可用", else: "已过期"
  end

  def audit_action_label("user_registered"), do: "用户注册"
  def audit_action_label("user_logged_in"), do: "用户登录"
  def audit_action_label("administrator_bootstrapped"), do: "创建或重置管理员"
  def audit_action_label("password_changed"), do: "修改密码"
  def audit_action_label("user_access_updated"), do: "更新用户角色或状态"
  def audit_action_label("vehicle_access_granted"), do: "授予车辆权限"
  def audit_action_label("vehicle_access_revoked"), do: "撤销车辆权限"
  def audit_action_label("vehicle_access_relinquished"), do: "用户解除车辆绑定"
  def audit_action_label("vehicle_claim_created"), do: "创建车辆认领码"
  def audit_action_label("vehicle_claim_redeemed"), do: "使用车辆认领码"
  def audit_action_label("vehicle_claim_revoked"), do: "撤销车辆认领码"
  def audit_action_label(action), do: action

  def location_label(record) do
    cond do
      is_nil(record) -> "未知位置"
      Map.get(record, :end_geofence) -> Fleet.address_label(record.end_geofence)
      Map.get(record, :end_address) -> Fleet.address_label(record.end_address)
      Map.get(record, :geofence) -> Fleet.address_label(record.geofence)
      Map.get(record, :address) -> Fleet.address_label(record.address)
      true -> Fleet.address_label(record)
    end
  end

  defp unit(nil, _precision, _suffix), do: "—"
  defp unit(value, precision, suffix), do: format_number(value, precision) <> suffix

  defp number(nil), do: 0.0
  defp number(%Decimal{} = value), do: Decimal.to_float(value)
  defp number(value) when is_integer(value), do: value * 1.0
  defp number(value) when is_float(value), do: value
  defp number(_), do: 0.0

  defp bar_height(_value, maximum) when maximum <= 0, do: 4
  defp bar_height(value, maximum), do: max(4, round(number(value) / maximum * 100))

  defp format_period(%NaiveDateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d")
  defp format_period(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d")
  defp format_period(value), do: to_string(value)

  defp compact_period(%NaiveDateTime{} = value), do: Calendar.strftime(value, "%m/%d")
  defp compact_period(%DateTime{} = value), do: Calendar.strftime(value, "%m/%d")
  defp compact_period(value), do: to_string(value)
end
