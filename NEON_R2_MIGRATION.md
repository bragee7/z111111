# Neon Postgres + Backblaze B2 setup (ZELDA server)

This is the current production storage setup:

- **Database:** Neon Postgres (pooled connection, SSL required).
- **SOS evidence:** Backblaze B2, private bucket, served through short-lived signed URLs.
- **Fallback:** Supabase Storage is still supported if B2/R2 are not configured.

## 1. Neon Postgres

1. Create a Neon project in a region close to the Render service (Oregon → AWS `us-west-2` works well).
2. Copy the **pooled** connection string from **Connect**. It looks like:
   ```
   postgresql://<user>:<password>@<endpoint>-pooler.<region>.aws.neon.tech/<db>?sslmode=require
   ```
3. Set these values locally in `server/config/config.env` (gitignored) or in Render:
   ```
   DATABASE_URL=postgresql://...
   DB_SSL=true
   ```
4. Apply the schema:
   ```bash
   psql "$DATABASE_URL" -f server/sql/schema_neon.sql
   ```
   The schema is idempotent: it creates `users`, `sos_cases`, `contacts`, `user_preferences`, `audit_log`, indexes, and two demo users only when missing.
5. Verify:
   ```sql
   select tablename from pg_tables where schemaname = 'public' order by tablename;
   select count(*) from users;
   ```
   Expected tables: `audit_log`, `contacts`, `sos_cases`, `user_preferences`, `users`.

Neon free tier auto-suspends after inactivity; the first request after a pause may take 1–2 seconds.

## 2. Backblaze B2 (SOS evidence)

1. Create a **private** bucket. The current bucket is `zeldadb`.
2. Create a **bucket-scoped** application key — never use the account Master key:
   - Name: `zelda-server`
   - Bucket: `zeldadb`
   - Capabilities: `listFiles`, `readFiles`, `writeFiles`, `deleteFiles`
3. Copy the **keyID** and **applicationKey**. The secret is shown only once.
4. Note the bucket region and S3 endpoint. Current values:
   - Region: `us-east-005`
   - Endpoint: `https://s3.us-east-005.backblazeb2.com`
5. Set:
   ```
   B2_KEY_ID=...
   B2_APPLICATION_KEY=...
   B2_BUCKET=zeldadb
   B2_REGION=us-east-005
   B2_ENDPOINT=https://s3.us-east-005.backblazeb2.com
   B2_PUBLIC_BASE_URL=
   ```
   Leave `B2_PUBLIC_BASE_URL` empty for a private bucket. The server stores durable
   `b2://bucket/key` references and creates short-lived presigned URLs when serving
   cases, email, exports, and API responses.

If `B2_PUBLIC_BASE_URL` is set, objects are treated as public and that base URL is
used directly. Do not make an evidence bucket public.

## 3. Cloudflare R2 (optional)

The server also supports R2 as a fallback S3 backend:

```
R2_ACCOUNT_ID=...
R2_ACCESS_KEY_ID=...
R2_SECRET_ACCESS_KEY=...
R2_BUCKET=sos-media
R2_PUBLIC_BASE_URL=https://pub-xxxxxxxxxxxxxxxx.r2.dev
R2_ENDPOINT=https://<account>.r2.cloudflarestorage.com
```

Backend selection order is **B2 → R2 → Supabase Storage**. `/api/config-status`
reports the active backend as `Configured (b2)`, `Configured (r2)`, or
`Not configured`.

## 4. Install and run locally

```bash
cd zelda1/server
npm install
npm run dev
```

Check:

- `GET /api/health` → `status: ok`
- `GET /api/health/db` → `ok: true`
- `GET /api/config-status` → `database: Connected`, `storage: Configured (b2)`

For production, keep `NODE_ENV=production` and provide a real `JWT_SECRET`
(`openssl rand -hex 32`). The server refuses to start in production without it.

## 5. Render deployment

`render.yaml` uses standard Render env syntax:

- `DATABASE_URL` — **secret**, set in the Render dashboard
- `DB_SSL=true`
- `JWT_SECRET` — **secret**
- `B2_KEY_ID` and `B2_APPLICATION_KEY` — **secrets**
- `B2_BUCKET=zeldadb`
- `B2_REGION=us-east-005`
- `B2_ENDPOINT=https://s3.us-east-005.backblazeb2.com`
- `B2_PUBLIC_BASE_URL=""`
- `NODE_ENV=production`
- `CORS_ORIGINS` — comma-separated browser origins (the mobile app does not need CORS)

The live mobile API is `https://zelda-api-kbtl.onrender.com`. The build command is
`npm ci --omit=dev`, so `package-lock.json` must be committed (it is no longer
ignored).

## 6. Verify end-to-end

1. Register/login a user.
2. Create an SOS with video and/or audio.
3. Confirm the case response contains a presigned HTTPS URL (private B2) and a
   `b2://zeldadb/...` reference is stored in `sos_cases`.
4. Confirm `/api/health/db` and `/api/config-status` show the expected backends.
5. Admin delete user → media objects are removed from B2.

## 7. Migrating existing data

```bash
pg_dump "$OLD_DATABASE_URL" --no-owner --no-acl -Fc -f zelda.dump
pg_restore --clean --if-exists -d "$DATABASE_URL" zelda.dump
```

To move existing evidence, copy objects from the old bucket to `zeldadb` (rclone
or a one-off script), then update `sos_cases.video_url` / `audio_url` to the new
`b2://` references.

## Notes

- Never commit `server/config/config.env` or any application key.
- Rotate any key that has been pasted into chat or a shared log.
- Add a retention/cleanup policy for old SOS evidence; video is the largest cost.
- Prefer private buckets plus signed URLs for all evidence.
