# ZELDA Offline-First SOS — Test Report

Status: **Implementation complete. Automated checks pass. Online, offline-queue, reboot-recovery, automatic-sync, session-fencing, and MP4 evidence paths verified on a real device against staging.** No push, commit, deploy, or real emergency alert has been performed.

Test date: 2026-11-04
Device: Redmi Note 13 5G (`t8wwmvdyvw4x8p99`), app `com.zelda.zeldav2`
Backend: local staging server `http://127.0.0.1:5000` (Neon `zelda_staging`, B2 `zelda-staging-1793769855`)
Build flags: `API_BASE_URL=http://127.0.0.1:5000`, `SOS_TEST_MODE=true`, `SOS_SEND_ENABLED=true`
Server env: `NODE_ENV=test`, `ALLOW_TEST_SOS=true`, `EMAIL_SMTP_ENABLED=false`

## 1. Automated checks

```text
flutter test
# 57 tests passed, 0 failed

flutter analyze --no-fatal-infos --no-fatal-warnings
# No issues found

node -e "require('./routes/sos.js')"
# sos route loads OK
```

Existing suites exercised: `cancel_sos_button`, `offline_assets`, `offline_router`, `sos_cancellation`, `sos_outbox`.

## 2. Device scenarios verified

### 2.1 Online SOS

Two manual SOS alerts were sent with the staging tunnel up. Each created exactly one staging case with `syncSource: online`, `evidenceStatus: complete`, matching local/server SHA-256, and B2 evidence. Cases 4, 5, and the final regression case 14 are the reference rows; case 14 stored a 30 s MP4 as `2354bcf8-31a1-448f-a25e-1ff1609d45d7.mp4` with SHA-256 `25e5e23838b5c94e75d74f9025e8a028e6a77ae6b53e2c278e51c7b140e3255f`.

### 2.2 Offline SOS (genuine network cut)

Airplane mode alone does not cut this debug build: the app talks to `127.0.0.1` through `adb reverse`, so the real network cut was **removing the USB tunnel** (`adb reverse --remove tcp:5000`) with airplane mode ON.

Result of one manual offline trigger:

- UI showed `Status: Recording`, then the red banner `Could not reach ZELDA servers. Your alert and evidence were saved on this phone and will be sent automatically when you are back online.`
- Local SQLite row status `PENDING_SYNC`, `sync_ready = 1`, evidence `complete` for the recorded track.
- Evidence stored at `files/sos_evidence/034086eb-a228-492f-a2e0-f7a106b57e3d/video.mp4` (17,185,282 bytes).
- Staging backend stayed at 5 cases while offline.

### 2.3 Automatic synchronization

After `cmd connectivity airplane-mode disable` and `adb reverse tcp:5000 tcp:5000`, the background sync worker delivered the queue without opening the app:

- Server went from 5 to 11 cases; all queued local rows became `SYNCED` with `server_case_id` 6–11.
- Case 11 (the manual offline alert): `triggerType app`, `syncSource offline_sync`, `evidenceStatus complete`, captured `2026-11-04T08:48:54.104Z` (see defect 3), received `09:00:27.386Z`, synced `09:01:36.241Z`, video SHA-256 `c9e661041916c50fd942da8af1619fce4d3164480d95a17f187d2f9c21ba69fc` matching the local hash.
- The five additional cases (6–10) were metadata-only rows produced by deliberate three-press power-button tests; each triple press is a separate alert and is not a duplicate-sync defect.

### 2.4 Reboot with pending records

Five queued `PENDING_SYNC` rows existed before a device reboot. After reboot, unlock, and app relaunch the app showed `Offline. Showing saved session.` and the rows were still present in SQLite. They all synced successfully once connectivity returned, confirming durable local persistence across process and device restarts.

### 2.5 Second-pass regression run (cases 12–14)

After the first fixes were installed, three more alerts were exercised:

- **Case 12** — offline manual trigger, audio-only. Captured `09:08:57.716Z` (real trigger time, proving the `captured_at` fix), `clockSkewSeconds null` (proving the clock-skew fix), and it auto-synced after the tunnel was restored.
- **Case 13** — online manual trigger. This exposed two additional lifecycle defects (foreground flag not pushed to the background executor, and a stale mirror snapshot being adopted by a new session), which caused an audio-only, stale file to be uploaded before the camera recording finished. Fixed below.
- **Case 14** — online manual trigger after those fixes. `evidenceStatus complete`, `videoUrl` key `.../2354bcf8-31a1-448f-a25e-1ff1609d45d7.mp4` (correct container extension), downloaded video SHA-256 matched the local `video_sha256`, no audio track (camera recording carries its own audio), and the local row is `SYNCED` with `server_case_id 14`.

Cases 12 and 13 are retained as staging-only regression artifacts; they are not production data.

## 3. Defects found during device testing (fixed)

1. **False clock-skew labels on delayed sync.**
   `clockSkewSeconds` was computed as `Math.abs(skew) > 300`, so a normal offline queue (case 11: `-693s`) was recorded as a bad device clock. Now only a `capturedAt` in the future (> 300 s ahead) is stored as clock skew; a past `capturedAt` is treated as delivery delay (`received_at - captured_at`). Documented in `OFFLINE_SOS_SYNC.md`.
2. **Wrong evidence extension.**
   The mobile client always uploaded the filename `emergency-video.webm`, so an MP4 recording was stored on B2 as `.webm`. The client now sends the real extension, and the server additionally sniffs the file header (ISO-BMFF `ftyp` → `.mp4`, Matroska → `.webm`, RIFF → `.wav`/`.avi`, ID3 → `.mp3`) before falling back to MIME/filename.
3. **`captured_at` inherited from a previous session.**
   The UI isolate read a cached `SharedPreferences` value; the background executor's fresh `capturedAtKey` was not visible, so case 11 reused case 10's `08:48:54.104Z` although the alert was triggered at `14:28:22` local. `SosController.sendEmergencyData()` now calls `prefs.reload()` before reading session state.
4. **Evidence-only retry is not a duplicate case.**
   `clientReference` idempotency is verified: retries with the same reference return the existing case (HTTP 200, `duplicate: true`) and only fill missing evidence; they never insert a second row.
5. **Foreground state not pushed on cold start.**
   The background isolate kept `appInForeground = false` because the `service_ready` event could arrive before the UI listener existed. A foreground SOS therefore used the native CameraX recorder, which conflicts with the Flutter preview and fell back to audio-only. `VoiceGuardService` now seeds the flag from `WidgetsBinding.instance.lifecycleState`, refreshes it on `service_ready`, and pushes the current value once after wiring the listener.
6. **Stale native recording command.**
   `SosRecordingService` never cleared `flutter.zelda_sos_native_command = start_recording`, so the guard service could restart phantom 30 s recordings after reboot. The service now consumes the command in `onStartCommand` and clears it in `finish()`/`onDestroy()`.
7. **Stale mirror evidence adopted by a new session.**
   A stale snapshot from the previous session could be adopted while a new trigger was starting, pairing old evidence with the new `captured_at` and sending metadata before the new recording existed. Both `_recoverStaleMirror` and `_adoptNativeDone` now require the snapshot `sessionId` to match the current session before sending.
8. **Late evidence never reconciled.**
   If evidence finished attaching after the case was already marked `SYNCED`, the local row kept a video path the server never received. `attachEvidence` now requeues the record (`PENDING_SYNC`) when paths change after sync, so the same `clientReference` fills the missing track on the next pass.
9. **Audio mislabeled as `.mp4`.**
   Header sniffing was applied to every upload, including M4A audio. Sniffing now runs only for the video field; audio keeps the MIME/filename-derived `.m4a` extension.

The five extra queued rows seen in the first offline run were caused by repeated deliberate power-button triple presses, not by the sync loop. Each campaign is treated as its own alert and is expected behaviour; no code change was made.

## 4. Scenarios still not covered

- Interrupted upload mid-flight and retry/backoff timing.
- The late-evidence requeue path (`attachEvidence` after `SYNCED`) is verified by
  code review and the server-side idempotent replay, but no device run has yet
  produced a case whose evidence attached after delivery. No unit test covers it
  because the logic lives inside the sqflite-backed store.
- `UPLOAD_FAILED` when a locally expected evidence file is missing or unreadable.
- Force-stop (process death) during recording, then cold-start recovery.
- Mobile-data/Wi-Fi toggles as distinct network paths (this build uses the adb loopback tunnel; airplane mode plus tunnel removal was the equivalent cut).
- Location tracking badge and live updates on the police dashboard after metadata-only delivery.
- Long-duration retry behaviour (backoff over hours, queue lease expiry).

## 5. Cleanup / production gate

- Staging-only credentials and URLs were used; production `https://zelda-api-kbtl.onrender.com` was never touched.
- No push, commit, or deploy has been performed.
- The temporary `[DEBUG LOGIN]` credential log was removed from `server/routes/auth.js`, and the untracked staging helper scripts were deleted.
- Before production: rotate the B2/Render/Brevo credentials exposed during staging setup.

## 6. Permission request

Online, offline, reboot-recovery, automatic-sync, and MP4 evidence paths are verified on staging. I will not push, commit, or deploy until you explicitly approve.
