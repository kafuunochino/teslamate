defmodule TeslaMate.TeslaFleet.Energy do
  @moduledoc """
  Immutable, timestamped energy history and shared session calculations.
  Callers must resolve vehicle access before requesting historical data.
  No latest-value substitution or retrospective rewriting of legacy records.
  """
  alias TeslaMate.Repo

  @history_fields ~w(EnergyRemaining Soc NominalFullPackEnergyKwh ACChargingEnergyIn DCChargingEnergyIn)
  @boundary_seconds 30
  @minimum_coverage 90

  def record(car_id, field, value, date) when field in @history_fields do
    Repo.insert_all(
      "fleet_energy_samples",
      [%{car_id: car_id, field: field, value: value, measured_at: date}],
      on_conflict: :nothing
    )

    :ok
  end

  def record(_, _, _, _), do: :ok

  # Lateral index lookups retrieve only the two boundaries per field/session,
  # rather than transferring years of telemetry into the web process.
  def boundaries(intervals, fields) do
    intervals =
      for interval <- intervals,
          match?(%DateTime{}, interval.start_date),
          match?(%DateTime{}, interval.end_date),
          DateTime.compare(interval.end_date, interval.start_date) == :gt do
        %{
          id: interval.id,
          car_id: interval.car_id,
          start_date: DateTime.to_iso8601(interval.start_date),
          end_date: DateTime.to_iso8601(interval.end_date)
        }
      end

    if intervals == [] do
      %{}
    else
      result =
        Repo.query!(
          """
          SELECT i.id, f.field, a.measured_at, a.value, b.measured_at, b.value,
                 EXTRACT(EPOCH FROM (i.end_date - i.start_date))::double precision,
                 EXTRACT(EPOCH FROM (a.measured_at - i.start_date))::double precision,
                 EXTRACT(EPOCH FROM (i.end_date - b.measured_at))::double precision,
                 CASE WHEN f.field NOT IN ('ACChargingEnergyIn', 'DCChargingEnergyIn') THEN true ELSE NOT EXISTS (
                   SELECT 1 FROM (
                     SELECT value, lag(value) OVER (ORDER BY measured_at) AS previous
                     FROM fleet_energy_samples
                     WHERE car_id = i.car_id AND field = f.field
                       AND measured_at >= a.measured_at AND measured_at <= b.measured_at
                   ) readings
                   WHERE value IS NULL OR value < previous
                 ) END AS counter_valid
          FROM jsonb_to_recordset($1::jsonb)
            AS i(id bigint, car_id bigint, start_date timestamp, end_date timestamp)
          CROSS JOIN unnest($2::text[]) AS f(field)
          CROSS JOIN LATERAL (
            SELECT measured_at, value FROM fleet_energy_samples
            WHERE car_id = i.car_id AND field = f.field
              AND measured_at >= i.start_date AND measured_at <= i.start_date + interval '30 seconds'
              AND measured_at <= i.end_date
            ORDER BY measured_at LIMIT 1
          ) a
          CROSS JOIN LATERAL (
            SELECT measured_at, value FROM fleet_energy_samples
            WHERE car_id = i.car_id AND field = f.field
              AND measured_at <= i.end_date AND measured_at >= i.end_date - interval '30 seconds'
              AND measured_at >= i.start_date
            ORDER BY measured_at DESC LIMIT 1
          ) b
          """,
          [intervals, fields]
        )

      Enum.reduce(result.rows, %{}, fn
        [id, field, first_at, first, last_at, last, duration, start_gap, end_gap, monotonic],
        acc ->
          first_at = DateTime.from_naive!(first_at, "Etc/UTC")
          last_at = DateTime.from_naive!(last_at, "Etc/UTC")
          span = DateTime.diff(last_at, first_at, :microsecond) / 1_000_000
          coverage = if duration > 0, do: span / duration * 100, else: 0

          if is_number(first) and is_number(last) and span > 0 and
               start_gap <= @boundary_seconds and end_gap <= @boundary_seconds and
               coverage >= @minimum_coverage do
            reading = %{
              first: first,
              last: last,
              first_at: first_at,
              last_at: last_at,
              coverage: coverage,
              monotonic: monotonic
            }

            Map.update(acc, id, %{field => reading}, &Map.put(&1, field, reading))
          else
            acc
          end
      end)
    end
  end

  def drive_energy(drives) do
    drives
    |> boundaries(["EnergyRemaining"])
    |> Map.new(fn {id, fields} ->
      sample = fields["EnergyRemaining"]

      {id,
       %{
         energy_kwh: sample.first - sample.last,
         source: :fleet_battery,
         start_energy: sample.first,
         end_energy: sample.last,
         start_sample_at: sample.first_at,
         end_sample_at: sample.last_at,
         coverage: sample.coverage
       }}
    end)
  end

  def charging_energy(sessions) do
    samples = boundaries(sessions, ["ACChargingEnergyIn", "DCChargingEnergyIn"])

    Map.new(sessions, fn session ->
      fields = Map.get(samples, session.id, %{})
      battery = counter(fields["DCChargingEnergyIn"])
      input = counter(fields["ACChargingEnergyIn"])
      # AC counters must not be used for a DC session. A measured positive AC
      # delta and absence of a fast-charger sample establish the AC side.
      input =
        if (Map.get(session, :fast_charger) == false and input) && input.energy > 0, do: input

      paired = battery && input && aligned?(battery, input)
      added = if battery, do: battery.energy, else: number(session.charge_energy_added)
      used = if input, do: input.energy, else: number(session.charge_energy_used)

      {loss, loss_percent} =
        if paired && input.energy >= battery.energy && input.energy > 0 do
          delta = input.energy - battery.energy
          {delta, delta / input.energy * 100}
        else
          {nil, nil}
        end

      {session.id,
       %{
         energy_added: added,
         energy_used: used,
         battery_source: if(battery, do: :fleet_battery, else: :vehicle_data),
         input_source: if(input, do: :fleet_ac, else: :power_estimate),
         loss_kwh: loss,
         loss_percent: loss_percent,
         loss_source: if(is_number(loss), do: :fleet_ac)
       }}
    end)
  end

  defp counter(%{monotonic: true, first: first, last: last} = sample)
       when first >= 0 and first <= 0.25 and last >= first,
       do: Map.put(sample, :energy, last - first)

  defp counter(_), do: nil

  defp aligned?(a, b) do
    abs(DateTime.diff(a.first_at, b.first_at, :millisecond)) <= 1000 and
      abs(DateTime.diff(a.last_at, b.last_at, :millisecond)) <= 1000
  end

  def capacity_history(car_id, since) do
    # Never mix direct capacity and normalized energy/SOC or rated-range bases.
    direct =
      Repo.query!(
        """
        SELECT (measured_at AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Shanghai')::date,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY value)
        FROM fleet_energy_samples
        WHERE car_id = $1 AND field = 'NominalFullPackEnergyKwh'
          AND measured_at >= $2 AND value > 0
        GROUP BY 1 ORDER BY 1
        """,
        [car_id, since]
      ).rows

    if direct != [] do
      %{source: :fleet_capacity, rows: capacity_rows(direct)}
    else
      paired =
        Repo.query!(
          """
          SELECT (e.measured_at AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Shanghai')::date,
                 percentile_cont(0.5) WITHIN GROUP (ORDER BY e.value / s.value * 100)
          FROM fleet_energy_samples e
          JOIN fleet_energy_samples s ON s.car_id = e.car_id AND s.field = 'Soc'
            AND s.measured_at = e.measured_at
          WHERE e.car_id = $1 AND e.field = 'EnergyRemaining'
            AND e.measured_at >= $2 AND e.value > 0 AND s.value BETWEEN 20 AND 95
          GROUP BY 1 ORDER BY 1
          """,
          [car_id, since]
        ).rows

      %{source: :fleet_normalized, rows: capacity_rows(paired)}
    end
  end

  defp capacity_rows(rows),
    do: Enum.map(rows, fn [period, value] -> %{period: period, value: value} end)

  defp number(%Decimal{} = value), do: Decimal.to_float(value)
  defp number(value) when is_number(value), do: value
  defp number(_), do: nil
end
