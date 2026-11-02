# Free-tier deployment overview

The old db4free/MySQL instructions in this file are obsolete. Current stack:

| Layer | Service | Free tier |
|-------|---------|-----------|
| API | Render Web Service | Free (sleeps when idle) |
| Database | Neon Postgres | Free, auto-suspend |
| SOS evidence | Backblaze B2 private bucket | 10 GB storage, no card required |
| Dashboard | Render static build or Vercel | Free |

## Steps

1. Create a Neon project and copy the **pooled** connection string.
2. Apply `server/sql/schema_neon.sql`.
3. Create a private B2 bucket and a **bucket-scoped** application key.
4. Set the environment variables listed in `DEPLOYMENT.md`.
5. Deploy `zelda1` to Render (repo root layout) with:
   - Build: `npm ci --omit=dev`
   - Start: `node server/index.js`
6. Verify `/api/health`, `/api/health/db`, and `/api/config-status`.

Full instructions:

- `DEPLOYMENT.md` — Render + dashboard deployment.
- `NEON_R2_MIGRATION.md` — Neon + B2 setup, schema, verification, migration.

## Notes

- Render free instances sleep; the first request after idle is slow.
- Neon free databases auto-suspend; first query may take 1–2 seconds.
- Keep the B2 bucket private. Evidence is served through short-lived signed URLs.
- Rotate any credential that was pasted into chat or committed by accident.
