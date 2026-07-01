defmodule TeslaMate.Repo.Migrations.AddSafeTimeOfUseCosts do
  use Ecto.Migration

  def up do
    create table(:tm_tou_rates) do
      add :geofence_id, references(:geofences, on_delete: :delete_all)
      add :hour_start, :integer, null: false
      add :hour_end, :integer, null: false
      add :rate, :decimal, precision: 10, scale: 4, null: false
      add :weekday_mask, :integer, null: false, default: 127
      add :valid_from, :date
      add :valid_to, :date
      add :apply_to_dc, :boolean, null: false, default: false
      add :label, :string
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    create index(:tm_tou_rates, [:geofence_id])

    create table(:tm_charging_costs, primary_key: false) do
      add :charging_process_id,
          references(:charging_processes, on_delete: :delete_all),
          primary_key: true

      add :cost_tou, :decimal, precision: 10, scale: 4, null: false
      add :computed_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    create constraint(:tm_tou_rates, :tm_tou_rates_hour_start_check,
             check: "hour_start BETWEEN 0 AND 23"
           )

    create constraint(:tm_tou_rates, :tm_tou_rates_hour_end_check,
             check: "hour_end BETWEEN 1 AND 24"
           )

    create constraint(:tm_tou_rates, :tm_tou_rates_hours_differ_check,
             check: "hour_start <> hour_end"
           )

    create constraint(:tm_tou_rates, :tm_tou_rates_rate_check, check: "rate >= 0")

    create constraint(:tm_tou_rates, :tm_tou_rates_weekday_mask_check,
             check: "weekday_mask BETWEEN 1 AND 127"
           )

    execute("""
    CREATE UNIQUE INDEX tm_tou_rates_unique_index ON public.tm_tou_rates (
      COALESCE(geofence_id, -1),
      hour_start,
      hour_end,
      COALESCE(valid_from, DATE '0001-01-01'),
      COALESCE(valid_to, DATE '9999-12-31'),
      apply_to_dc
    )
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.tm_tou_in_season(
      sample_date DATE,
      valid_from DATE,
      valid_to DATE
    ) RETURNS BOOLEAN AS $$
      SELECT CASE
        WHEN valid_from IS NULL AND valid_to IS NULL THEN TRUE
        WHEN valid_from IS NULL THEN
          to_char(sample_date, 'MMDD') <= to_char(valid_to, 'MMDD')
        WHEN valid_to IS NULL THEN
          to_char(sample_date, 'MMDD') >= to_char(valid_from, 'MMDD')
        WHEN to_char(valid_from, 'MMDD') <= to_char(valid_to, 'MMDD') THEN
          to_char(sample_date, 'MMDD') BETWEEN
            to_char(valid_from, 'MMDD') AND to_char(valid_to, 'MMDD')
        ELSE
          to_char(sample_date, 'MMDD') >= to_char(valid_from, 'MMDD')
          OR to_char(sample_date, 'MMDD') <= to_char(valid_to, 'MMDD')
      END;
    $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path = pg_catalog, public;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.tm_lookup_tou_rate(
      sample_ts TIMESTAMP,
      charging_geofence_id INTEGER,
      charging_is_dc BOOLEAN
    ) RETURNS NUMERIC AS $$
    DECLARE
      local_ts TIMESTAMP;
      sample_hour INTEGER;
      sample_day INTEGER;
      sample_date DATE;
      bit_position INTEGER;
      matched_rate NUMERIC;
    BEGIN
      IF sample_ts IS NULL THEN
        RETURN NULL;
      END IF;

      local_ts := (sample_ts AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Shanghai';
      sample_hour := EXTRACT(HOUR FROM local_ts)::INTEGER;
      sample_date := local_ts::DATE;
      sample_day := EXTRACT(DOW FROM local_ts)::INTEGER;
      bit_position := CASE WHEN sample_day = 0 THEN 6 ELSE sample_day - 1 END;

      SELECT rate INTO matched_rate
      FROM public.tm_tou_rates
      WHERE (geofence_id = charging_geofence_id OR geofence_id IS NULL)
        AND apply_to_dc = COALESCE(charging_is_dc, FALSE)
        AND (
          (hour_start < hour_end AND sample_hour >= hour_start AND sample_hour < hour_end)
          OR (hour_start > hour_end AND (sample_hour >= hour_start OR sample_hour < hour_end))
          OR (hour_start = 0 AND hour_end = 24)
        )
        AND ((weekday_mask >> bit_position) & 1) = 1
        AND public.tm_tou_in_season(sample_date, valid_from, valid_to)
      ORDER BY
        (geofence_id = charging_geofence_id) DESC,
        (valid_from IS NOT NULL OR valid_to IS NOT NULL) DESC,
        id
      LIMIT 1;

      RETURN matched_rate;
    END;
    $$ LANGUAGE plpgsql STABLE
    SET search_path = pg_catalog, public;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.tm_compute_tou_cost(process_id INTEGER)
    RETURNS NUMERIC AS $$
    DECLARE
      charging_geofence_id INTEGER;
      charging_is_dc BOOLEAN;
      actual_kwh NUMERIC;
      weighted_rate NUMERIC;
    BEGIN
      SELECT geofence_id, GREATEST(charge_energy_added, charge_energy_used)
      INTO charging_geofence_id, actual_kwh
      FROM public.charging_processes
      WHERE id = process_id;

      IF actual_kwh IS NULL THEN
        RETURN NULL;
      END IF;

      IF actual_kwh <= 0 THEN
        RETURN 0;
      END IF;

      SELECT COALESCE(NOT bool_or(charger_phases IS NOT NULL), FALSE)
      INTO charging_is_dc
      FROM public.charges
      WHERE charging_process_id = process_id;

      WITH samples AS (
        SELECT
          date,
          COALESCE(charger_power, 0) AS charger_power,
          LEAD(date) OVER (ORDER BY date) AS next_date
        FROM public.charges
        WHERE charging_process_id = process_id
      ),
      priced AS (
        SELECT
          GREATEST(
            charger_power * EXTRACT(EPOCH FROM (next_date - date)) / 3600.0,
            0
          ) AS sample_kwh,
          public.tm_lookup_tou_rate(date, charging_geofence_id, charging_is_dc) AS rate
        FROM samples
        WHERE next_date IS NOT NULL
          AND EXTRACT(EPOCH FROM (next_date - date)) BETWEEN 0 AND 600
      )
      SELECT CASE
        WHEN COALESCE(SUM(sample_kwh), 0) <= 0 THEN NULL
        WHEN COUNT(*) FILTER (WHERE sample_kwh > 0 AND rate IS NULL) > 0 THEN NULL
        ELSE SUM(sample_kwh * rate) / NULLIF(SUM(sample_kwh), 0)
      END
      INTO weighted_rate
      FROM priced;

      IF weighted_rate IS NULL THEN
        RETURN NULL;
      END IF;

      RETURN ROUND((actual_kwh * weighted_rate)::NUMERIC, 4);
    END;
    $$ LANGUAGE plpgsql STABLE
    SET search_path = pg_catalog, public;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.tm_effective_cost(
      process_id INTEGER,
      fallback NUMERIC
    ) RETURNS NUMERIC AS $$
      SELECT COALESCE(
        (
          SELECT cost_tou
          FROM public.tm_charging_costs
          WHERE charging_process_id = process_id
        ),
        fallback
      );
    $$ LANGUAGE sql STABLE PARALLEL SAFE
    SET search_path = pg_catalog, public;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.tm_trigger_compute_tou()
    RETURNS TRIGGER AS $$
    DECLARE
      computed NUMERIC;
    BEGIN
      computed := public.tm_compute_tou_cost(NEW.id);

      IF computed IS NOT NULL THEN
        INSERT INTO public.tm_charging_costs (charging_process_id, cost_tou, computed_at)
        VALUES (NEW.id, computed, NOW())
        ON CONFLICT (charging_process_id) DO UPDATE
        SET cost_tou = EXCLUDED.cost_tou,
            computed_at = NOW();
      ELSE
        DELETE FROM public.tm_charging_costs WHERE charging_process_id = NEW.id;
      END IF;

      RETURN NEW;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'TOU calculation failed for charging_process_id=%: %', NEW.id, SQLERRM;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    SET search_path = pg_catalog, public;
    """)

    execute("""
    CREATE TRIGGER tm_tou_recalculate
    AFTER INSERT OR UPDATE OF end_date, charge_energy_added, charge_energy_used, geofence_id
    ON public.charging_processes
    FOR EACH ROW
    WHEN (NEW.end_date IS NOT NULL)
    EXECUTE FUNCTION public.tm_trigger_compute_tou()
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.tm_backfill_tou()
    RETURNS TABLE(processed INTEGER, updated INTEGER, skipped INTEGER) AS $$
    DECLARE
      item RECORD;
      computed NUMERIC;
      processed_count INTEGER := 0;
      updated_count INTEGER := 0;
      skipped_count INTEGER := 0;
    BEGIN
      FOR item IN
        SELECT id FROM public.charging_processes WHERE end_date IS NOT NULL ORDER BY id
      LOOP
        processed_count := processed_count + 1;
        computed := public.tm_compute_tou_cost(item.id);

        IF computed IS NULL THEN
          DELETE FROM public.tm_charging_costs WHERE charging_process_id = item.id;
          skipped_count := skipped_count + 1;
        ELSE
          INSERT INTO public.tm_charging_costs (charging_process_id, cost_tou, computed_at)
          VALUES (item.id, computed, NOW())
          ON CONFLICT (charging_process_id) DO UPDATE
          SET cost_tou = EXCLUDED.cost_tou,
              computed_at = NOW();
          updated_count := updated_count + 1;
        END IF;
      END LOOP;

      RETURN QUERY SELECT processed_count, updated_count, skipped_count;
    END;
    $$ LANGUAGE plpgsql
    SET search_path = pg_catalog, public;
    """)

    execute("REVOKE ALL ON FUNCTION public.tm_backfill_tou() FROM PUBLIC")
    execute("REVOKE ALL ON FUNCTION public.tm_trigger_compute_tou() FROM PUBLIC")

    execute(
      "COMMENT ON TABLE public.tm_tou_rates IS 'Optional time-of-use electricity rates; does not modify TeslaMate core costs'"
    )

    execute(
      "COMMENT ON TABLE public.tm_charging_costs IS 'Calculated TOU costs stored separately from charging_processes.cost'"
    )
  end

  def down do
    execute("DROP TRIGGER IF EXISTS tm_tou_recalculate ON public.charging_processes")
    execute("DROP FUNCTION IF EXISTS public.tm_backfill_tou()")
    execute("DROP FUNCTION IF EXISTS public.tm_trigger_compute_tou()")
    execute("DROP FUNCTION IF EXISTS public.tm_effective_cost(INTEGER, NUMERIC)")
    execute("DROP FUNCTION IF EXISTS public.tm_compute_tou_cost(INTEGER)")
    execute("DROP FUNCTION IF EXISTS public.tm_lookup_tou_rate(TIMESTAMP, INTEGER, BOOLEAN)")
    execute("DROP FUNCTION IF EXISTS public.tm_tou_in_season(DATE, DATE, DATE)")
    drop table(:tm_charging_costs)
    drop table(:tm_tou_rates)
  end
end
