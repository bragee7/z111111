# Women Safety Guardian - Complete Full-Stack Application

## Overview
A comprehensive women safety emergency response system with real-time SOS alerts, voice-triggered emergency detection, media recording, and police dashboard for case management.

## Features

### User (Victim) Dashboard
- 🚨 **Voice Auto-Start** - Voice recognition automatically starts when user logs in
- 🚨 **Voice Trigger Detection** - Continuously listens for "Help Me", "Emergency", or "Save Me"
- 🎥 **Automatic Video Recording** - 30-second emergency recording using MediaRecorder API
- 📍 **Fresh Location Capture** - GPS location captured at time of SOS trigger
- 🔊 **Alert Sound** - Audio notification when emergency is triggered
- ⏱️ **Countdown Timer** - 3-2-1 countdown before recording starts
- 💾 **Local Backup** - Save recordings to your device
- 📱 **Media Preview** - Watch and listen to your recordings immediately

### Police Dashboard
- 📊 **Real-time Case List** - Live updates every 10 seconds
- 🚨 **New Alert Animation** - Visual and audio notification for new emergencies
- 🎬 **Media Playback** - Video and audio evidence viewer
- 📍 **Location Links** - Direct Google Maps integration
- 📝 **Case Notes** - Add and update case notes
- ✅ **Status Management** - Mark cases as Pending/Resolved

## Tech Stack

### Frontend
- React.js 18
- Tailwind CSS
- Vite (build tool)
- React Router v6
- Axios (API client)

### Backend
- Node.js
- Express.js
- JWT Authentication
- Multer (file uploads)
- bcryptjs (password hashing)

### Storage
- MySQL (database `zelda_new`) via `mysql2` connection pool
- Local file system for media uploads

## Mobile App (Flutter)

An Android Flutter app with feature parity to the web client is in `mobile/`,
including the 24/7 background voice listener (Vosk offline speech recognition in
a foreground service). See [mobile/README.md](mobile/README.md) for build,
run, and demo instructions.

## Quick Start

### 1. Start Backend Server
```bash
cd server
npm install
npm run dev
```
Server runs on: http://localhost:5000

### 2. Start Frontend Dev Server
```bash
cd client
npm install
npm run dev
```
Client runs on: http://localhost:3000

### 3. Access the Application
Open browser: http://localhost:3000

## Demo Accounts

### Police Account
- Email: police@guardian.com
- Password: police123
- Role: Police Dashboard access

### User Account
- Email: user@guardian.com
- Password: user123
- Role: User Dashboard with SOS features

## How to Use

### For Users (Victims)
1. Register or login with your credentials
2. Voice recognition automatically starts when you log in - no manual activation needed
3. Say "Help Me", "Emergency", or "Save Me" to trigger SOS
4. Alternatively, click the large "SEND SOS ALERT" button anytime
5. Your current location will be captured at time of alert
6. Recording will start after 3-second countdown
7. Your location, video, and audio will be sent to police
8. **Save to Device**: After recording, download your video and audio files directly to your device
   - Preview recordings in the app
   - Click "Download Video" or "Download Audio" buttons
   - Click "Download All Files" to save both at once

### For Police
1. Login with police credentials
2. View all emergency cases in real-time
3. Click on a case to view details
4. Watch video and listen to audio
5. Click location to open Google Maps
6. Add notes and mark cases as resolved

## API Endpoints

### Authentication
- `POST /api/auth/register` - Create new account
- `POST /api/auth/login` - Login and get JWT token

### SOS Cases
- `POST /api/sos` - Create new SOS alert (with video/audio upload)
- `GET /api/sos` - Get all cases (police: all, user: own cases)
- `GET /api/sos/:id` - Get single case details
- `PUT /api/sos/:id` - Update case status/notes
- `GET /api/sos/:id/timeline` - Get full audit timeline for a case
- `GET /api/preferences` - Get user's voice guard phrases
- `PUT /api/preferences` - Update user's voice guard phrases (max 10)

## ZELDA Free Features 1-15

### F1 - WhatsApp Share
Share a case location instantly via WhatsApp with a formatted link (Web, Case Details page).

### F2 - Live Maps
Live interactive maps (Leaflet + OpenStreetMap) showing emergency case locations (Web, Police Dashboard + Case Details).

### F3 - SHA-256 Integrity
Every video/audio upload is hashed with SHA-256; hashes are stored and displayed so evidence integrity can be verified.

### F4 - Rate Limiting
Login, registration and OTP endpoints are rate-limited (login: 10/min, register: 5/60min, OTP: 10/min) to prevent brute force.

### F5 - Idle Auto-Logout
Web sessions log out automatically after 15 minutes of inactivity for security.

### F6 - Custom Voice Phrases
Users define up to 10 custom voice phrases (default: `help me`) that trigger an SOS when spoken. Editable in the mobile app, synced via `/api/preferences`.

### F7 - Priority Contacts
Emergency contacts have a priority (P1-P5, P1 = highest). Mobile app shows priority badges and sends alerts in priority order.

### F8 - Closure Workflow
Police can resolve a case with a required closure reason (`False Alarm`, `Victim Safe`, `Police Intervention`, `Emergency Resolved`, `Duplicate Case`, `Other`). Closure events are audited.

### F9 - Case Timeline
Every case exposes its full audit timeline (created, status changes, notes, location updates, closure) via `/api/sos/:id/timeline`.

### F10 - Profile Management
Users can view and update their name, email and password from the profile page.

### F11 - GDPR Export
Users can download their full personal data (profile, contacts, SOS cases) as JSON, per GDPR Article 20.

### F12 - Response Time
System tracks `first_response_at` per case and reports average/max response times overall and per officer (`/api/admin/stats/response-times`).

### F13 - Officer KPIs
Per-officer performance dashboard: cases handled, resolved/pending counts, average response time (`/api/admin/stats/officer-kpis`).

### F14 - Overview Stats
Admin dashboard charts: case status distribution, weekly/monthly case trend with toggle, and a geographic case heatmap (`/api/admin/stats/status-distribution`, `/series`, `/geo`).

### F15 - Web Floating SOS
One-tap floating SOS button on the web (user role) that sends an SOS with the current geolocation to police.

### Database Migration
- `features_1_15_columns`: added `closure_reason`, `first_response_at`, `video_sha256`, `audio_sha256` to `sos_cases`; `priority` to `contacts`; new `user_preferences` table with RLS.

### Deployed Commits
- `3eea683` - Phase 1 (F4, F5, F10, F11)
- `7c31d9c` - Phase 2 (F1, F2, F3, F7, F8, F9, F12, F13)
- `4b8172d` - Phase 4/5 (F14, F6, F15)
- `88f08c0` - Fix: preferences user id mapping

## Project Structure

```
Root/
├── client/                 # React Frontend
│   ├── src/
│   │   ├── components/    # Reusable components
│   │   ├── pages/         # Page components
│   │   ├── services/      # API services
│   │   ├── context/       # React contexts
│   │   ├── App.jsx        # Main app component
│   │   └── main.jsx       # Entry point
│   ├── package.json
│   └── vite.config.js
│
├── server/                 # Node.js Backend
│   ├── routes/            # API routes
│   ├── middleware/        # Auth middleware
│   ├── data/              # JSON data files
│   ├── uploads/           # Uploaded media files
│   ├── index.js          # Express server
│   └── package.json
│
└── README.md
```

## Key Features Implementation

### Voice Recognition
Uses Web Speech API for continuous voice recognition:
- Supports Chrome browser
- Detects keywords: "HELP ME", "EMERGENCY", "SAVE ME"
- Works in background while page is active

### Media Recording
Uses MediaRecorder API:
- Captures both video and audio
- 30-second maximum duration
- Stores as WebM format
- Auto-stops and sends when complete

### Geolocation
Uses browser Geolocation API:
- High accuracy mode
- Falls back gracefully if denied
- Generates Google Maps link

### Real-time Updates
- Police dashboard polls every 10 seconds
- New alert detection and notification
- Optimistic UI updates

## Security Features
- JWT-based authentication
- Password hashing with bcrypt
- Protected API routes
- Role-based access control
- CORS configuration

## Browser Compatibility
- Chrome (recommended for voice features)
- Firefox
- Edge
- Safari (limited voice support)

## Future Enhancements
- [ ] Push notifications
- [ ] SMS integration
- [ ] Email alerts
- [x] Mobile app version (Android / Flutter)
- [ ] Cloud storage for media
- [ ] Multi-language support

## License
MIT License - Built for safety and protection

## Support
For emergency services, always call local authorities first.
This app is a tool to assist, not replace emergency services.
