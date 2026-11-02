# ZELDA - Women Safety Guardian (Mobile)

Flutter Android app for the Women Safety Guardian system. User-facing companion
to the React dashboard (the police/admin dashboard is web-only), with the 24/7
background voice listener and a fully offline police-station directory.

## Features

### User Dashboard
- SOS alert with 5s cancel window, 3-2-1 countdown, and automatic 30s video + audio recording
- Failed alerts are saved to an app-private outbox with their evidence and retried automatically for up to 24h (max 5 alerts)
- Fresh GPS location captured and sent with each alert
- Live location tracking (30s updates) after an alert is sent
- Emergency contacts CRUD
- Media preview after recording

### Voice Protection (24/7)
- On-device keyword spotting with sherpa-onnx (int8 Zipformer KWS); no network
  is used and audio never leaves the phone
- Runs in a foreground service (`flutter_background_service`) with a persistent
  notification, using the `microphone` foreground type
- **Auto-starts on login** for user accounts (requests `RECORD_AUDIO` +
  `POST_NOTIFICATIONS` at runtime via `permission_handler`); stops on logout
- Default trigger phrase: **"Help me"**. Up to three custom phrases can be saved
  from the dashboard and persist across restarts.
- Input conditioning: software AGC, 80 Hz high-pass, hardware AGC/AEC/NS where
  available, and an SNR gate before a trigger is accepted
- The KWS session is rebuilt every 8 minutes so a long-running service cannot
  silently stop hearing the microphone
- On detection while the app is backgrounded, a full-screen intent notification
  brings the app to the foreground to run the SOS flow
- The int8 KWS model (~5.2 MB) is bundled under `assets/kws/`; the downloader is
  only a fallback if the bundled copy is missing or corrupt
- The dashboard switch reflects the real foreground-service status and surfaces
  startup errors (e.g. missing `RECORD_AUDIO` permission)

### Verified on a real device (Vivo V30)
- Voice auto-start after login: foreground service with `microphone` type +
  persistent notification confirmed; the dashboard switch reflects live state
- Real-mic keyword test: saying "help me" triggered the full SOS flow
  (cancel window → countdown → 30s recording → upload) and created a case with
  live GPS; the case appeared on the police dashboard with the LIVE tracking badge
- The live location card populates on the dashboard via the background position watch

### Police Stations (directory + map + routing)
- Full Tamil Nadu police-station directory — **1,317 stations across 46 districts**
- Search by name / district / station id, plus one-tap **district chips**
- **Nearest stations** by live GPS, sorted by real distance
- **OpenStreetMap** map (no API key) with station pins, your location pin and the
  route line
- Tap a station for full details: address, phone, coordinates, distance
- **Turn-by-turn route** to any station, or to the **nearest** one by real
  **road** distance (not just straight-line) — Drive / Walk / Bike
- **Follow me**: the map tracks your live position, and if you drift more than
  120 m off the route it warns you and recalculates automatically
- **District helplines** for all 46 districts, tap to call

#### Works with NO server — online *and* offline

Everything above runs from **bundled assets**; the backend is only a bonus.

| Asset | Size | What it gives |
|---|---|---|
| `assets/tn_stations.json.gz` | 47 KB | all 1,317 stations with address, phone, coordinates |
| `assets/tn_helplines.json.gz` | 1 KB | the 46 district control-room numbers |
| `assets/tn_roads.bin.gz` | 22.9 MB | **on-device A\* routing** over the OSM road network (~2.08M nodes / 2.11M edges) |

- `lib/services/offline_data_service.dart` — gunzips and parses the assets once,
  then serves everything from RAM.
- `lib/services/offline_router.dart` — **A\* on device** over a compact binary
  road graph (CSR adjacency, binary min-heap, haversine heuristic). The
  heuristic is admissible, so A\* returns the **true shortest road path** — the
  same answer class as the online Valhalla/OSRM engines. Turn-by-turn is
  generated on device from bearings.
- `lib/services/police_station_service.dart` — **offline-first**. Bundled data
  is authoritative; a reachable server is used only to *enrich* it. Routing
  tries the online engine first (better instructions), then falls back to the
  local A\* router. The UI shows an **"Offline mode"** banner so you always know
  which path is in use.

Rebuild the assets with:
```bash
cd server && node tools/build_offline_assets.js
```

> **Road graph.** `assets/tn_roads.bin.gz` is built from OpenStreetMap via the
> Overpass API and committed with the app. It contains roughly 2.08M nodes and
> 2.11M edges covering Tamil Nadu, so offline routing works out of the box.
> Re-run the command above if the OSM extract changes; the new file replaces the
> old one and the app picks it up with no code change.

The directory, routing and the OSM map are all **free and key-less**:
ERSS/SOS_MEAP for the station data, OpenStreetMap for tiles, Valhalla (with
OSRM fallback) for routing.

The backend exposes the same data under `/api/police-stations/*`:
`list`, `districts`, `cities`, `nearby`, `route`, `nearest-route`, `hydrate`.

> **Deployment note.** The police-station routes are **new server code**
> (`server/routes/policeStations.js` + `server/services/policeStationRouter.js`).
> They only exist on the server once those files are deployed. `render.yaml`
> auto-deploys the **Render service `zelda-api-kbtl`** from the repo
> `bragee7/z111111`, which is *not* this clone's `origin`
> (`unknown235669-cmyk/zelda1-full`) — so push the server changes to the repo
> Render watches, or the app will get a 404 for `/api/police-stations/*`.
>
> For local testing, point the app at your own machine:
> ```bash
> flutter run --dart-define=API_BASE_URL=http://<your-lan-ip>:5000
> ```

### Alert history
- List of the user's past SOS cases with status
- Case details with media playback and a location link
- Export a case report as PDF (Android print dialog)

The **police/admin dashboard** (real-time Socket.IO case list, notes, status
changes) is the React web client in `../client`; it is not bundled in the
mobile app.

## Requirements
- Flutter SDK 3.x (Dart 3.x)
- Android emulator or device (API 26+ recommended)
- Backend optional: login, case sync and server-side alerts need it, but the
  station directory, map and routing work without it

## Run

```bash
cd mobile
flutter pub get
flutter run
```

To point the app at a different backend, override the base URL at build time
(uses `https://zelda-api-kbtl.onrender.com` by default):

```bash
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:5000
```

## Build

```bash
# Per-ABI release APKs (recommended for direct distribution)
flutter build apk --release --split-per-abi

# Play Store bundle
flutter build appbundle --release
```

The split build produces three APKs: `app-armeabi-v7a-release.apk` (~61 MB),
`app-arm64-v8a-release.apk` (~71 MB, most modern phones) and
`app-x86_64-release.apk` (~76 MB, emulators). A universal `flutter build apk`
packages the ONNX Runtime native libraries for every ABI and is roughly 155 MB,
so prefer split APKs or an App Bundle. Release signing uses `key.properties`
when present; otherwise Gradle falls back to debug signing.

### Voice service prerequisites on emulator
- `RECORD_AUDIO` and `POST_NOTIFICATIONS` runtime permissions. Grant manually if
  the system dialog was skipped:
  ```
  adb shell pm grant com.zelda.zelda_guardian android.permission.RECORD_AUDIO
  adb shell pm grant com.zelda.zelda_guardian android.permission.POST_NOTIFICATIONS
  ```
- First toggle of "24/7 Voice Protection" extracts the bundled model (takes ~1-2s).

## Demo accounts
- Police: `police@guardian.com` / `police123`
- User: `user@guardian.com` / `user123`

## Project layout
```
lib/
  main.dart                       App entry; initializes VoiceGuardService
  core/                           Theme, shared widgets, API + socket clients
  models/                         Data models (user, contact, station, SOS case)
  screens/
    login_screen.dart             Email/password + OTP registration
    user_dashboard_screen.dart    SOS, voice toggle, contacts, alert history
    police_stations_screen.dart   Offline directory, map and routing
    case_details_screen.dart      Media, status and PDF export
  services/
    voice_guard_service.dart      Foreground service + on-device KWS
    keyword_model_manager.dart    Bundled KWS assets, download fallback
    sos_executor.dart             Background-isolate SOS state machine
    sos_outbox.dart               Durable retry queue for undelivered SOS alerts
    offline_data_service.dart     Gunzip + parse bundled stations/helplines
    offline_router.dart           On-device A* routing
    police_station_service.dart   Offline-first station lookup
  state/
    auth_provider.dart            JWT auth state
    sos_controller.dart           SOS flow state
    contacts_provider.dart        Emergency contacts state
    police_stations_provider.dart Station directory state
```

## Known limitations
- Keyword detection cannot be exercised on the Android emulator (no real mic
  input); test it on a physical device. Asset/unit tests verify that the model
  loads, the keyword table builds, and the recognizer starts.
- SOS **delivery** needs connectivity. Detection, countdown, recording and the
  offline map work without a network. If the alert cannot reach the backend, the
  alert and its recorded evidence are stored in a local outbox and retried every
  60 seconds for up to 24 hours (maximum 5 queued alerts). There is still no SMS
  fallback, and delivery is at-least-once: in the rare case where the server
  created the case but the response was lost, a retry can create a duplicate.
- The pulsing SOS button glow animation continuously redraws; on an emulator this
  keeps CPU elevated. Acceptable on device.
