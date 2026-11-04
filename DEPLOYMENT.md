# Deployment Guide — ZELDA backend

Current target: **Render** for the Express API and **Neon Postgres + Backblaze B2**
for data and evidence. The React dashboard is built into `client/dist` and served
by the same Express process.

## Live service

| Item | Value |
|------|-------|
| API | `https://zelda-api-kbtl.onrender.com` |
| Render service | `zelda-api-kbtl` |
| Render repo | `bragee7/z111111` (repo root = contents of `zelda1/`) |
| Health | `GET /api/health` |
| Database | Neon Postgres (pooled, SSL) |
| Evidence | Backblaze B2 private bucket `zeldadb` |

The local `origin` remote is `unknown235669-cmyk/zelda1-full`, which is **not**
the repo Render watches. Deploying to the live service requires pushing the
`zelda1` subtree to `bragee7/z111111` (root layout, no nested `zelda1/` folder).

## 1. Prerequisites

- Render account with access to the live service (or a new Blueprint).
- Neon project and pooled `DATABASE_URL`.
- B2 bucket + bucket-scoped application key.
- A `JWT_SECRET` generated with:
  ```bash
  node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
  ```

## 2. Render environment variables

Set these in the Render dashboard (or via a Blueprint). Mark the secrets as
secret/sync-false; never commit them.

```
NODE_ENV=production
DATABASE_URL=postgresql://...        # Neon pooled connection string
DB_SSL=true
JWT_SECRET=<64-char hex>
B2_KEY_ID=<bucket-scoped key id>
B2_APPLICATION_KEY=<bucket-scoped application key>
B2_BUCKET=zeldadb
B2_REGION=us-east-005
B2_ENDPOINT=https://s3.us-east-005.backblazeb2.com
B2_PUBLIC_BASE_URL=
CORS_ORIGINS=https://zelda-api-kbtl.onrender.com
CLIENT_URL=https://zelda-api-kbtl.onrender.com
API_URL=https://zelda-api-kbtl.onrender.com
EMAIL_FROM=ZELDA <your-verified-sender>
POLICE_EMAIL=police@guardian.com
```

Optional: `SENDGRID_API_KEY` for SOS email notifications.

CORS is allow-list based (`server/config/origins.js`). Native mobile clients send
no `Origin` header and are allowed. Add any Vercel/custom dashboard domain to
`CORS_ORIGINS` (comma-separated).

## 3. Build and start

```
Build:  npm ci --omit=dev
Start:  node server/index.js
Health: /api/health
```

`package-lock.json` must be committed for `npm ci`. If you cannot commit it,
change the build command to `npm install --omit=dev`.

The server refuses to start in production without a real `JWT_SECRET`.

## 4. Database schema

Create the base schema once per Neon database:

```bash
psql "$DATABASE_URL" -f server/sql/schema_neon.sql
```

The script is idempotent. It creates `users`, `sos_cases`, `contacts`,
`user_preferences`, `audit_log`, indexes, and demo accounts
(`police@guardian.com` / `user@guardian.com`).

Incremental changes live in `server/sql/migrations/` and are applied
**automatically on server start**. Each file runs once and is recorded in
`schema_migrations`; the whole run is wrapped in a transaction guarded by a
Postgres advisory lock, and a failure stops the process instead of serving a
mismatched schema. Set `SKIP_DB_MIGRATIONS=true` only for read-only replicas.
The applied versions are visible at `GET /api/health/db`.

## 5. Deploying the frontend

The Express server serves `client/dist` with an SPA fallback. Build it before
starting the server:

```bash
cd client
npm ci
npm run build
```

To host the dashboard separately on Vercel:

| Setting | Value |
|---------|-------|
| Framework | Vite |
| Root Directory | `client` |
| Build Command | `npm run build` |
| Output Directory | `dist` |
| `VITE_API_URL` | `https://zelda-api-kbtl.onrender.com/api` |
| `VITE_MEDIA_URL` | `https://zelda-api-kbtl.onrender.com` |

Then add the Vercel domain to `CORS_ORIGINS` on Render.

## 6. Verify

```bash
curl https://zelda-api-kbtl.onrender.com/api/health
curl https://zelda-api-kbtl.onrender.com/api/health/db
curl https://zelda-api-kbtl.onrender.com/api/config-status
```

Expected:

- `/api/health` → `status: ok`, `database: connected`
- `/api/health/db` → `ok: true`, five tables
- `/api/config-status` → `database: Connected`, `storage: Configured (b2)`,
  `jwt: Configured`

## 7. Evidence and filesystem

SOS video/audio is uploaded to B2, not to Render's ephemeral disk. Uploads are
written to a temp file, hashed (SHA-256), uploaded to B2, then the temp file is
removed. Private objects are served through short-lived presigned URLs.

## 8. Demo accounts

| Role | Email | Password |
|------|-------|----------|
| Police | `police@guardian.com` | `police123` |
| User | `user@guardian.com` | `user123` |

Change or remove these before a real public launch.

## Related docs

- `NEON_R2_MIGRATION.md` — Neon + B2 setup and verification.
- `DEPLOY-FREE.md` — free-tier overview (points here).
