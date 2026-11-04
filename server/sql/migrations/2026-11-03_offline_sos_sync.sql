-- Offline-first SOS synchronization migration.
-- Safe to run more than once. Apply before deploying the matching API code:
--   psql "$DATABASE_URL" -f server/sql/migrations/2026-11-03_offline_sos_sync.sql
--
-- captured_at  = when the phone captured the emergency (may be hours before receipt)
-- received_at  = when this server accepted the case
-- synced_at    = when all expected evidence was verified by the server
-- client_reference = stable UUID generated on the phone, used for idempotency

ALTER TABLE sos_cases ADD COLUMN IF NOT EXISTS client_reference TEXT;
ALTER TABLE sos_cases ADD COLUMN IF NOT EXISTS captured_at TIMESTAMPTZ;
ALTER TABLE sos_cases ADD COLUMN IF NOT EXISTS received_at TIMESTAMPTZ;
ALTER TABLE sos_cases ADD COLUMN IF NOT EXISTS synced_at TIMESTAMPTZ;
ALTER TABLE sos_cases ADD COLUMN IF NOT EXISTS sync_source TEXT NOT NULL DEFAULT 'online';
ALTER TABLE sos_cases ADD COLUMN IF NOT EXISTS evidence_status TEXT NOT NULL DEFAULT 'none';
ALTER TABLE sos_cases ADD COLUMN IF NOT EXISTS device_id TEXT;
ALTER TABLE sos_cases ADD COLUMN IF NOT EXISTS app_version TEXT;
ALTER TABLE sos_cases ADD COLUMN IF NOT EXISTS is_test BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE sos_cases ADD COLUMN IF NOT EXISTS clock_skew_seconds INTEGER;

-- Backfill old rows without pretending they were received at migration time.
UPDATE sos_cases SET received_at = created_at WHERE received_at IS NULL;
UPDATE sos_cases SET captured_at = created_at WHERE captured_at IS NULL;
UPDATE sos_cases
SET evidence_status = CASE
  WHEN video_url IS NOT NULL OR audio_url IS NOT NULL THEN 'complete'
  ELSE 'none'
END
WHERE evidence_status = 'none';

ALTER TABLE sos_cases ALTER COLUMN received_at SET NOT NULL;
ALTER TABLE sos_cases ALTER COLUMN received_at SET DEFAULT now();

CREATE UNIQUE INDEX IF NOT EXISTS uq_sos_cases_client_ref
  ON sos_cases(user_id, client_reference)
  WHERE client_reference IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_sos_cases_received_at
  ON sos_cases(received_at DESC);
