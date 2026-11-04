-- Zelda Women Safety Guardian - Postgres schema for Neon (or any Postgres)
-- Run once against DATABASE_URL:
--   psql "$DATABASE_URL" -f server/sql/schema_neon.sql
-- Safe to re-run: uses IF NOT EXISTS.

CREATE TABLE IF NOT EXISTS users (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE,
  personal_email TEXT,
  password TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'user',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_verified BOOLEAN NOT NULL DEFAULT false,
  otp TEXT,
  otp_expiry TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS sos_cases (
  id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_email TEXT,
  location_link TEXT,
  latitude TEXT,
  longitude TEXT,
  status TEXT NOT NULL DEFAULT 'Pending',
  notes TEXT,
  video_url TEXT,
  audio_url TEXT,
  video_sha256 TEXT,
  audio_sha256 TEXT,
  -- Offline-first synchronization metadata.
  client_reference TEXT,
  captured_at TIMESTAMPTZ,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  synced_at TIMESTAMPTZ,
  sync_source TEXT NOT NULL DEFAULT 'online',
  evidence_status TEXT NOT NULL DEFAULT 'none',
  device_id TEXT,
  app_version TEXT,
  is_test BOOLEAN NOT NULL DEFAULT false,
  clock_skew_seconds INTEGER,
  trigger_type TEXT NOT NULL DEFAULT 'manual',
  priority TEXT NOT NULL DEFAULT 'Medium',
  case_type TEXT,
  assigned_officer TEXT,
  closure_reason TEXT,
  first_response_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  nearest_police_station_name TEXT,
  nearest_police_station_address TEXT,
  nearest_police_station_lat DOUBLE PRECISION,
  nearest_police_station_lng DOUBLE PRECISION,
  nearest_police_station_distance_m INTEGER,
  nearest_police_station_osm_id BIGINT,
  nearest_police_station_osm_type TEXT,
  nearest_police_station_fetched_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS contacts (
  id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  phone TEXT NOT NULL,
  email TEXT,
  relation TEXT,
  priority INTEGER NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS user_preferences (
  user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  voice_phrases JSONB NOT NULL DEFAULT '["help me"]'::jsonb
);

CREATE TABLE IF NOT EXISTS audit_log (
  id SERIAL PRIMARY KEY,
  user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
  case_id INTEGER REFERENCES sos_cases(id) ON DELETE SET NULL,
  action TEXT,
  details TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sos_cases_user_id ON sos_cases(user_id);
CREATE INDEX IF NOT EXISTS idx_sos_cases_status ON sos_cases(status);
CREATE INDEX IF NOT EXISTS idx_sos_cases_received_at ON sos_cases(received_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS uq_sos_cases_client_ref
  ON sos_cases(user_id, client_reference)
  WHERE client_reference IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_contacts_user_id ON contacts(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_user_id ON audit_log(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_case_id ON audit_log(case_id);

-- Optional demo accounts (passwords match the documented demo credentials).
INSERT INTO users (name, email, personal_email, password, role, created_at, updated_at, is_verified)
VALUES
  ('Police Officer', 'police@guardian.com', NULL, '$2a$10$bfA8EVj4PtNoPtWQNWOGyehpzoTH0Hp3p9nWIm4F2UI.swU0vJe9e', 'police', now(), now(), true),
  ('Test User', 'user@guardian.com', NULL, '$2a$10$YeExqZbWQrhCxnLe7Bafru5/9tAudCRjm1s2FnSjRVah6yVmJIIFG', 'user', now(), now(), true)
ON CONFLICT (email) DO NOTHING;
