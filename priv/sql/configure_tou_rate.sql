-- Add or replace one time-of-use electricity rate without modifying
-- charging_processes.cost. Run with psql after TeslaMate migrations:
--
-- psql -U teslamate -d teslamate \
--   -v geofence_id='' -v hour_start=22 -v hour_end=8 \
--   -v rate=0.30 -v label='谷' -v apply_to_dc=false \
--   -f priv/sql/configure_tou_rate.sql
--
-- geofence_id='' means the global default. Use an integer to limit the rate
-- to one geofence. Re-run for every peak/flat/valley period.

\set ON_ERROR_STOP on

\if :{?hour_start}
\else
  \echo 'ERROR: pass -v hour_start=0..23'
  \quit 1
\endif
\if :{?hour_end}
\else
  \echo 'ERROR: pass -v hour_end=1..24'
  \quit 1
\endif
\if :{?rate}
\else
  \echo 'ERROR: pass -v rate=...'
  \quit 1
\endif
\if :{?label}
\else
  \set label ''
\endif
\if :{?geofence_id}
\else
  \set geofence_id ''
\endif
\if :{?apply_to_dc}
\else
  \set apply_to_dc false
\endif

INSERT INTO public.tm_tou_rates (
  geofence_id,
  hour_start,
  hour_end,
  rate,
  label,
  apply_to_dc,
  updated_at
) VALUES (
  NULLIF(:'geofence_id', '')::INTEGER,
  :'hour_start'::INTEGER,
  :'hour_end'::INTEGER,
  :'rate'::NUMERIC,
  NULLIF(:'label', ''),
  :'apply_to_dc'::BOOLEAN,
  NOW()
)
ON CONFLICT (
  COALESCE(geofence_id, -1),
  hour_start,
  hour_end,
  COALESCE(valid_from, DATE '0001-01-01'),
  COALESCE(valid_to, DATE '9999-12-31'),
  apply_to_dc
)
DO UPDATE SET
  rate = EXCLUDED.rate,
  label = EXCLUDED.label,
  updated_at = NOW();

SELECT id, geofence_id, hour_start, hour_end, rate, label, apply_to_dc
FROM public.tm_tou_rates
ORDER BY geofence_id NULLS FIRST, apply_to_dc, hour_start;

\echo 'Rate saved. After all periods are configured, run: SELECT * FROM tm_backfill_tou();'
