# ZELDA Offline-First SOS Sync

Status: implementation complete, automated/device testing not yet run.

This document describes how an SOS is saved on the phone, how it reaches the
police dashboard, and how the client and server guarantee that a delayed or
interrupted alert is not lost or duplicated.

## 1. Contract

An SOS has two independent states:

| Layer | Field | Meaning |
|---|---|---|
| Device | `local_sos.status` | `PENDING_SYNC`, `UPLOADING`, `SYNCED`, `UPLOAD_FAILED`, `RETRY_PENDING` |
| Police case | `sos_cases.status` | `Pending`, `Accepted`, `Resolved`, etc. |

The device state tracks delivery. The police state tracks the response. They
must never be written into the same column.

### Timestamps

| Field | Set by | Meaning |
|---|---|---|
| `captured_at` | Phone | The moment the user triggered the SOS. Never replaced by the server. |
| `received_at` | Server | The moment the case row was inserted. |
| `synced_at` | Server | The moment metadata and all expected evidence were verified. |
| `created_at` | Server | Legacy insert time, kept for old clients. New rows equal `received_at`. |

`clock_skew_seconds` is stored only when the device clock is more than five
minutes **ahead** of the server (a `captured_at` in the future). A late
offline delivery is expected, so a past `captured_at` is never reported as
clock skew — use `received_at - captured_at` for the delivery delay.

### Sync sources

- `online`: metadata and evidence were received in one prompt flow.
- `offline_sync`: the record was saved locally first, then delivered later.
  The server also derives this when `received_at - captured_at > 60s`, even if
  the phone crashed before updating its own source.

## 2. Device flow

1. The user triggers SOS. The device captures `capturedAt` immediately and
   starts the normal five-second cancel window.
2. When recording starts, `SosExecutor` creates a SQLite row with status
   `PENDING_SYNC` and `sync_ready = 0`.
3. Video/audio are copied from the camera/temporary location into
   `applicationSupport/sos_evidence/<local_id>/`, hashed with SHA-256, and the
   row is marked `sync_ready = 1`.
4. `SosSyncCoordinator` acquires a SQLite lease and uploads metadata plus
   evidence as one multipart request with a stable `clientReference`.
5. If the server has created the case but evidence is incomplete, the row stays
   retryable or becomes `UPLOAD_FAILED`; it is never called `SYNCED`.
6. A confirmed response with matching hashes sets `SYNCED`, stores the server
   case id and `received_at`, and starts live-location tracking.
7. If a media file finishes attaching after the case was already delivered,
   `attachEvidence` requeues the row as `PENDING_SYNC`. The next attempt reuses
   the same `clientReference`; the server returns the existing case and uploads
   only the missing track, so late evidence is still reconciled.
8. Mirror snapshots are session-fenced: evidence from an older session is never
   paired with a newer session's `captured_at`.
9. `UPLOAD_FAILED` and `RETRY_PENDING` records are kept. Evidence is not
   deleted because of age or queue length.

### Retry policy

- Backoff: 30 seconds, 2 minutes, 5 minutes, 15 minutes, 30 minutes.
- Connectivity changes kick the coordinator immediately while the app or
  foreground service is alive.
- WorkManager runs a periodic sync every 15 minutes with a network constraint
  and a one-off sync when an SOS is queued.
- WorkManager and the foreground service both use the same DB lease, so only
  one of them uploads a record at a time.
- Automatic workers skip `UPLOAD_FAILED` records. A manual "retry now" action
  may call `syncPending(force: true, includeFailed: true)`.
- A 401/403 pauses the record and keeps the evidence. The record resumes after
  the same user signs in again.

### Evidence rules

- Evidence stays in app-private internal storage.
- `allowBackup="false"` is already set.
- Files are hashed locally; the server returns its own SHA-256 values.
- A record is `SYNCED` only when the server case id exists and every expected
  file's hash matches.
- If a locally expected file is permanently gone, the alert metadata is still
  delivered once and the record becomes `UPLOAD_FAILED` with
  `evidenceStatus = missing`; the dashboard flags the missing evidence.
- Successfully synced records keep evidence for seven days by default, then
  `purgeSynced()` may remove only those files. Unsynchronized records are
  never purged.

## 3. Server API

### `POST /api/sos`

Multipart form. Existing fields are unchanged.

New fields:

| Field | Required | Notes |
|---|---|---|
| `clientReference` | yes for new clients | UUID-like, 8-120 chars, stable for the life of the alert. |
| `capturedAt` | yes | ISO-8601 device timestamp. |
| `syncSource` | no | `online` or `offline_sync`; server derives delay if omitted. |
| `deviceId` | no | Random installation id, not Android ID. |
| `appVersion` | no | Build version. |
| `evidenceExpected` | no | Whether evidence was recorded. |
| `videoExpected` | no | Whether a video file is expected. |
| `audioExpected` | no | Whether a separate audio file is expected. |
| `triggerType` | no | `manual`, `voice`, `power`, etc. Default `manual`. |
| `isTest` | no | Only honored when `ALLOW_TEST_SOS=true` and NODE_ENV is not production. |

Files: `video`, `audio`.

The server inserts the case first, emits `new_case`, then uploads evidence and
emits `case_updated`. A retry with the same `(user_id, client_reference)`
returns HTTP 200 with `duplicate: true` and the existing case. Existing
evidence is immutable.

Response:

```json
{
  "message": "SOS case created",
  "duplicate": false,
  "case": {
    "id": 123,
    "capturedAt": "2026-11-03T14:02:11.000Z",
    "receivedAt": "2026-11-03T14:37:42.000Z",
    "syncedAt": "2026-11-03T14:38:10.000Z",
    "syncSource": "offline_sync",
    "evidenceStatus": "complete",
    "videoSha256": "...",
    "audioSha256": "...",
    "isTest": false
  }
}
```

### Database migration

For an existing database, apply:

```
zelda1/server/sql/migrations/2026-11-03_offline_sos_sync.sql
```

For a new database, `zelda1/server/sql/schema_neon.sql` already contains the
columns and indexes. The migration adds:

- `client_reference`, `captured_at`, `received_at`, `synced_at`
- `sync_source`, `evidence_status`
- `device_id`, `app_version`, `is_test`, `clock_skew_seconds`
- unique partial index `uq_sos_cases_client_ref`
- index on `received_at`

Apply it before deploying the new server build. The route falls back to the old
schema on PostgreSQL error `42703`, but offline sync metadata is not persisted
in that mode.

### Test mode

```
ALLOW_TEST_SOS=true
NODE_ENV=test
EMAIL_SMTP_ENABLED=false
```

Mobile build flag:

```
--dart-define=SOS_TEST_MODE=true
```

The app sends `X-Zelda-Test: 1`. The dashboard displays a `TEST` badge. Test
cases must never be sent to a production police dashboard.

## 4. Police dashboard

`PoliceDashboard.jsx` and `CaseDetails.jsx` now display:

- **Reported** (`capturedAt`) and **Received** (`receivedAt`).
- Sync delay in minutes.
- `OFFLINE SYNC` badge.
- `TEST` badge.
- Evidence status: uploading, partial, failed, missing.
- The case report PDF includes the same fields.

New-case alerts still use the 10-second poll fallback. The server also emits
`new_case` and `case_updated` over Socket.IO for clients that subscribe.

## 5. Files

New mobile files:

- `mobile/lib/core/connectivity_service.dart`
- `mobile/lib/services/sos_local_store.dart`
- `mobile/lib/services/sos_sync_coordinator.dart`
- `mobile/lib/services/sos_background_sync.dart`

Modified mobile files:

- `mobile/lib/services/sos_executor.dart`
- `mobile/lib/services/sos_service.dart`
- `mobile/lib/models/sos_case.dart`
- `mobile/lib/state/sos_controller.dart`
- `mobile/lib/main.dart`
- `mobile/android/app/src/main/AndroidManifest.xml`
- `mobile/pubspec.yaml`

Server:

- `server/routes/sos.js`
- `server/index.js`
- `server/sql/schema_neon.sql`
- `server/sql/migrations/2026-11-03_offline_sos_sync.sql`

Dashboard:

- `client/src/pages/PoliceDashboard.jsx`
- `client/src/pages/CaseDetails.jsx`
- `client/dist/*` rebuilt with Vite 5.4.21.

## 6. Background execution limits

Android does not guarantee instant background execution after process death.
The implementation uses:

- Existing `PowerGuardService` for immediate retries while protection is on.
- WorkManager periodic work (minimum 15 minutes) with a network constraint.
- WorkManager one-off work on queue/reconnect.
- BootReceiver already restarts `PowerGuardService` after reboot.
- SQLite state survives process death and reboot.

Doze and OEM battery managers can delay WorkManager. The UI must not promise
"sent" until the coordinator confirms the server case and evidence hashes.

## 7. Test plan

Automated:

- Server: duplicate `clientReference`, timestamp preservation, delayed sync
  source, partial/missing evidence, test-mode gating.
- Flutter: state transitions, lease exclusivity, legacy outbox migration,
  hash verification, terminal `UPLOAD_FAILED` handling.

Manual device matrix:

1. Online SOS.
2. Mobile data disabled.
3. Wi-Fi disabled.
4. Completely offline.
5. Restore mobile data.
6. Restore Wi-Fi.
7. Interrupt upload halfway.
8. Restart the app with pending records.
9. Terminate the app process.
10. Reboot the device.
11. Verify exactly one case per SOS.
12. Verify all expected evidence is present and playable.

Testing requires explicit user permission, a staging backend, test accounts,
and `SOS_TEST_MODE=true`. Do not trigger real emergency alerts.

## 8. Known limitations

- No SMS fallback. The feature only guarantees server delivery when internet
  returns.
- Evidence retries restart the whole file. There is no byte-range resume; the
  SHA-256 check prevents corrupt or partial files from being accepted.
- JWT access tokens currently last seven days. If a phone is offline longer,
  sync pauses at 401 until the user signs in again. Refresh-token rotation is
  the recommended follow-up.
- Render free-tier cold starts can delay the first reconnect attempt. Retries
  handle it.
- Android may delay WorkManager in Doze. A running foreground service is
  faster but is not guaranteed after process death.
- If the device has no free space, the SQLite row can still be written but the
  evidence copy may fail; this is surfaced as missing evidence, never hidden.
