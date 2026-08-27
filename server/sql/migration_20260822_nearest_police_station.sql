-- Migration 20260822 — nearest police station snapshot (Tamil Nadu scoped, OSM Overpass)
-- Postgres. Idempotent. Snapshot at SOS creation; historic rows stay NULL.

ALTER TABLE sos_cases
  ADD COLUMN IF NOT EXISTS nearest_police_station_name TEXT,
  ADD COLUMN IF NOT EXISTS nearest_police_station_address TEXT,
  ADD COLUMN IF NOT EXISTS nearest_police_station_lat DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS nearest_police_station_lng DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS nearest_police_station_distance_m INTEGER,
  ADD COLUMN IF NOT EXISTS nearest_police_station_osm_id BIGINT,
  ADD COLUMN IF NOT EXISTS nearest_police_station_osm_type TEXT,
  ADD COLUMN IF NOT EXISTS nearest_police_station_fetched_at TIMESTAMPTZ;

-- No index needed (never filtered on, only read with case row). Add later if admin analytics need it:
-- CREATE INDEX IF NOT EXISTS idx_sos_cases_nearest_station ON sos_cases(nearest_police_station_distance_m);
