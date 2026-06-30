defmodule TeslaMate.Repo.Migrations.AddChinaMapCoordinateFunctions do
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION public.tm_is_outside_china(lat DOUBLE PRECISION, lng DOUBLE PRECISION)
    RETURNS BOOLEAN AS $$
      SELECT lng < 72.004 OR lng > 137.8347 OR lat < 0.8293 OR lat > 55.8271;
    $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path = pg_catalog, public;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.tm_wgs84_to_gcj02_lat(
      wgs_lat DOUBLE PRECISION,
      wgs_lng DOUBLE PRECISION
    ) RETURNS DOUBLE PRECISION AS $$
    DECLARE
      a CONSTANT DOUBLE PRECISION := 6378245.0;
      ee CONSTANT DOUBLE PRECISION := 0.00669342162296594323;
      x DOUBLE PRECISION;
      y DOUBLE PRECISION;
      d_lat DOUBLE PRECISION;
      rad_lat DOUBLE PRECISION;
      magic DOUBLE PRECISION;
      sqrt_magic DOUBLE PRECISION;
    BEGIN
      IF wgs_lat IS NULL OR wgs_lng IS NULL THEN
        RETURN NULL;
      END IF;

      IF public.tm_is_outside_china(wgs_lat, wgs_lng) THEN
        RETURN wgs_lat;
      END IF;

      x := wgs_lng - 105.0;
      y := wgs_lat - 35.0;
      d_lat := -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x));
      d_lat := d_lat + (20.0 * sin(6.0 * x * pi()) + 20.0 * sin(2.0 * x * pi())) * 2.0 / 3.0;
      d_lat := d_lat + (20.0 * sin(y * pi()) + 40.0 * sin(y / 3.0 * pi())) * 2.0 / 3.0;
      d_lat := d_lat + (160.0 * sin(y / 12.0 * pi()) + 320.0 * sin(y * pi() / 30.0)) * 2.0 / 3.0;
      rad_lat := wgs_lat / 180.0 * pi();
      magic := sin(rad_lat);
      magic := 1 - ee * magic * magic;
      sqrt_magic := sqrt(magic);
      d_lat := (d_lat * 180.0) / ((a * (1 - ee)) / (magic * sqrt_magic) * pi());

      RETURN wgs_lat + d_lat;
    END;
    $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    SET search_path = pg_catalog, public;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.tm_wgs84_to_gcj02_lng(
      wgs_lat DOUBLE PRECISION,
      wgs_lng DOUBLE PRECISION
    ) RETURNS DOUBLE PRECISION AS $$
    DECLARE
      a CONSTANT DOUBLE PRECISION := 6378245.0;
      ee CONSTANT DOUBLE PRECISION := 0.00669342162296594323;
      x DOUBLE PRECISION;
      y DOUBLE PRECISION;
      d_lng DOUBLE PRECISION;
      rad_lat DOUBLE PRECISION;
      magic DOUBLE PRECISION;
      sqrt_magic DOUBLE PRECISION;
    BEGIN
      IF wgs_lat IS NULL OR wgs_lng IS NULL THEN
        RETURN NULL;
      END IF;

      IF public.tm_is_outside_china(wgs_lat, wgs_lng) THEN
        RETURN wgs_lng;
      END IF;

      x := wgs_lng - 105.0;
      y := wgs_lat - 35.0;
      d_lng := 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x));
      d_lng := d_lng + (20.0 * sin(6.0 * x * pi()) + 20.0 * sin(2.0 * x * pi())) * 2.0 / 3.0;
      d_lng := d_lng + (20.0 * sin(x * pi()) + 40.0 * sin(x / 3.0 * pi())) * 2.0 / 3.0;
      d_lng := d_lng + (150.0 * sin(x / 12.0 * pi()) + 300.0 * sin(x * pi() / 30.0)) * 2.0 / 3.0;
      rad_lat := wgs_lat / 180.0 * pi();
      magic := sin(rad_lat);
      magic := 1 - ee * magic * magic;
      sqrt_magic := sqrt(magic);
      d_lng := (d_lng * 180.0) / (a / sqrt_magic * cos(rad_lat) * pi());

      RETURN wgs_lng + d_lng;
    END;
    $$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    SET search_path = pg_catalog, public;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.tm_lat_for_map(
      map_url TEXT,
      wgs_lat DOUBLE PRECISION,
      wgs_lng DOUBLE PRECISION
    ) RETURNS DOUBLE PRECISION AS $$
      SELECT CASE
        WHEN map_url ILIKE '%autonavi%'
        THEN public.tm_wgs84_to_gcj02_lat(wgs_lat, wgs_lng)
        ELSE wgs_lat
      END;
    $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path = pg_catalog, public;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION public.tm_lng_for_map(
      map_url TEXT,
      wgs_lat DOUBLE PRECISION,
      wgs_lng DOUBLE PRECISION
    ) RETURNS DOUBLE PRECISION AS $$
      SELECT CASE
        WHEN map_url ILIKE '%autonavi%'
        THEN public.tm_wgs84_to_gcj02_lng(wgs_lat, wgs_lng)
        ELSE wgs_lng
      END;
    $$ LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path = pg_catalog, public;
    """)
  end

  def down do
    execute(
      "DROP FUNCTION IF EXISTS public.tm_lng_for_map(TEXT, DOUBLE PRECISION, DOUBLE PRECISION)"
    )

    execute(
      "DROP FUNCTION IF EXISTS public.tm_lat_for_map(TEXT, DOUBLE PRECISION, DOUBLE PRECISION)"
    )

    execute(
      "DROP FUNCTION IF EXISTS public.tm_wgs84_to_gcj02_lng(DOUBLE PRECISION, DOUBLE PRECISION)"
    )

    execute(
      "DROP FUNCTION IF EXISTS public.tm_wgs84_to_gcj02_lat(DOUBLE PRECISION, DOUBLE PRECISION)"
    )

    execute(
      "DROP FUNCTION IF EXISTS public.tm_is_outside_china(DOUBLE PRECISION, DOUBLE PRECISION)"
    )
  end
end
