const express = require('express');
const http = require('http');
const cors = require('cors');
const path = require('path');
const rateLimit = require('express-rate-limit');

const config = require('./config');
const { isAllowedOrigin } = require('./config/origins');
const { pool } = require('./db');
const { runMigrations } = require('./db/migrations');
const storage = require('./storage');
const { initSocket } = require('./socket');
const authRoutes = require('./routes/auth');
const sosRoutes = require('./routes/sos');
const contactsRoutes = require('./routes/contacts');
const adminRoutes = require('./routes/admin');
const preferencesRoutes = require('./routes/preferences');
const policeStationRoutes = require('./routes/policeStations');

const app = express();
const PORT = config.server.port;
const httpServer = http.createServer(app);

initSocket(httpServer);

app.set('trust proxy', 1);

const rateLimitMsg = 'Too many requests. Please try again later.';
const rlWindowMs = Number(process.env.RATE_LIMIT_WINDOW) || 15 * 60 * 1000;
const rlMax = Number(process.env.RATE_LIMIT_MAX) || 300;

const generalLimiter = rateLimit({
  windowMs: rlWindowMs,
  max: rlMax,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: rateLimitMsg }
});

const strictLimiter = (windowMs, max) =>
  rateLimit({
    windowMs,
    max,
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: rateLimitMsg }
  });

app.use(cors({
  origin: (origin, callback) => callback(null, isAllowedOrigin(origin)),
  methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization', 'X-Zelda-Test'],
  maxAge: 86400
}));
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

app.use('/api/', generalLimiter);
app.use('/api/auth/login', strictLimiter(rlWindowMs, 10));
app.use('/api/auth/register', strictLimiter(60 * 60 * 1000, 5));
app.use('/api/auth/verify-otp', strictLimiter(rlWindowMs, 10));
app.use('/api/auth/resend-otp', strictLimiter(rlWindowMs, 10));
// SOS creation is retried by the offline sync engine. Keep a strict ceiling,
// but leave enough headroom for evidence retries and duplicate replays.
// Explicit next() fall-through to the sosRoutes router mounted below
// (app.use('/api/sos', sosRoutes) handles POST /).
app.post('/api/sos', strictLimiter(rlWindowMs, 60), (req, res, next) => next());

// Cheap connectivity probe for the mobile offline-sync engine. Deliberately
// does not touch the database so a cold Neon instance cannot look "offline".
app.get('/api/ping', (req, res) => res.status(204).end());

app.use('/uploads', express.static(path.join(__dirname, 'uploads')));

const initDB = async () => {
  try {
    const connection = await pool.connect();
    console.log('✅ Database connected successfully!');
    console.log(`🐘 Postgres via Neon/Supabase`);
    // Verify critical tables exist
    const tables = await connection.query("SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename IN ('users','sos_cases','contacts','audit_log','user_preferences')");
    console.log(`📋 Tables found: ${tables.rows.map(r=>r.tablename).join(', ') || '(none — run schema.sql!)'}`);
    connection.release();
  } catch (error) {
    console.error('❌ Database connection failed:', error.code || '', error.message);
    console.error('   → Check DATABASE_URL on Render → Environment. Supabase may be PAUSED — resume in Supabase Dashboard.');
    console.error('   → Verify connection string uses correct password & host (db.<ref>.supabase.co) and ?sslmode=require');
  }
};

initDB();

app.use('/api/auth', authRoutes);
app.use('/api/sos', sosRoutes);
app.use('/api/contacts', contactsRoutes);
app.use('/api/admin', adminRoutes);
  app.use('/api/preferences', preferencesRoutes);
// Police-station directory + routing: PUBLIC (directory data, no PII) so the
// mobile app can read it before the user logs in.
app.use('/api/police-stations', policeStationRoutes);

app.get('/api/health', async (req, res) => {
  // Real liveness: ping DB instead of just checking env presence
  let dbStatus = 'not configured';
  let dbError = null;
  if (config.db.connectionString) {
    try {
      const c = await pool.connect();
      await c.query('SELECT 1');
      c.release();
      dbStatus = 'connected';
    } catch (e) {
      dbStatus = 'error';
      dbError = `${e.code || ''} ${e.message}`.trim();
    }
  }
  res.json({
    status: dbStatus === 'connected' ? 'ok' : 'degraded',
    message: 'Women Safety Guardian API is running',
    config: {
      db: dbStatus,
      dbError: dbError || undefined,
      email: config.email.user ? 'configured' : 'not configured'
    }
  });
});

// Lightweight DB probe without auth — for Render debugging
app.get('/api/health/db', async (req, res) => {
  if (!config.db.connectionString) return res.status(500).json({ ok: false, error: 'DATABASE_URL not set on server' });
  try {
    const c = await pool.connect();
    const r = await c.query('SELECT 1 as ok');
    const t = await c.query("SELECT tablename FROM pg_tables WHERE schemaname='public' LIMIT 5");
    const m = await c
      .query('SELECT version FROM schema_migrations ORDER BY version')
      .catch(() => ({ rows: [] }));
    c.release();
    res.json({
      ok: true,
      probe: r.rows[0],
      tables: t.rows.map(x => x.tablename),
      migrations: m.rows.map(x => x.version)
    });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message, code: e.code || null });
  }
});

app.get('/api/config-status', (req, res) => {
  const supabaseConfigured = config.supabase.url && (config.supabase.serviceRoleKey || config.supabase.anonKey);
  const storageConfigured = storage.isConfigured();
  res.json({
    database: config.db.connectionString ? '✅ Connected' : '❌ Not configured',
    storage: storageConfigured ? 'Configured (' + storage.configuredBackend() + ')' : 'Not configured',
    supabase: supabaseConfigured ? 'Configured' : 'Not configured',
    jwt: config.jwt.secret ? '✅ Configured' : '❌ Not configured',
    email: config.email.sendgridApiKey ? '✅ Configured (SendGrid)' : '⚠️ Not configured (SOS emails will not be sent)',
    policeEmail: config.email.policeEmail || 'Not set'
  });
});

const distPath = path.join(__dirname, '../client/dist');

app.use(express.static(distPath));

app.get('*', (req, res) => {
  res.sendFile(path.join(distPath, 'index.html'));
});

const start = async () => {
  try {
    const { applied } = await runMigrations();
    if (applied.length > 0) {
      console.log(`🗃️  Applied migrations: ${applied.join(', ')}`);
    }
  } catch (error) {
    // Never serve traffic against a schema the code does not understand.
    console.error(`❌ ${error.message}`);
    process.exit(1);
  }

  httpServer.listen(PORT, () => {
    console.log(`🚀 Women Safety Guardian running on http://localhost:${PORT}`);
    console.log(`🐘 Database: Postgres (Neon/Supabase)`);
    console.log(`📧 Email: ${config.email.user || 'Not configured'}`);
    console.log(`👮 Police Email: ${config.email.policeEmail}`);
  });
};

start();