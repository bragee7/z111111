const express = require('express');
const http = require('http');
const cors = require('cors');
const path = require('path');
const rateLimit = require('express-rate-limit');

const config = require('./config');
const { pool } = require('./db');
const { initSocket } = require('./socket');
const authRoutes = require('./routes/auth');
const sosRoutes = require('./routes/sos');
const contactsRoutes = require('./routes/contacts');
const adminRoutes = require('./routes/admin');
const preferencesRoutes = require('./routes/preferences');

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

app.use('/api/', generalLimiter);
app.use('/api/auth/login', strictLimiter(rlWindowMs, 10));
app.use('/api/auth/register', strictLimiter(60 * 60 * 1000, 5));
app.use('/api/auth/verify-otp', strictLimiter(rlWindowMs, 10));
app.use('/api/auth/resend-otp', strictLimiter(rlWindowMs, 10));
app.post('/api/sos', strictLimiter(rlWindowMs, 10));

app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

app.use('/uploads', express.static(path.join(__dirname, 'uploads')));

const initDB = async () => {
  try {
    const connection = await pool.connect();
    console.log('✅ Database connected successfully!');
    console.log(`🐘 Postgres via Supabase`);
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
    c.release();
    res.json({ ok: true, probe: r.rows[0], tables: t.rows.map(x=>x.tablename) });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message, code: e.code || null });
  }
});

app.get('/api/config-status', (req, res) => {
  const supabaseConfigured = config.supabase.url && (config.supabase.serviceRoleKey || config.supabase.anonKey);
  res.json({
    database: config.db.connectionString ? '✅ Connected' : '❌ Not configured',
    supabase: supabaseConfigured ? '✅ Configured' : '❌ Not configured',
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

httpServer.listen(PORT, () => {
  console.log(`🚀 Women Safety Guardian running on http://localhost:${PORT}`);
  console.log(`🐘 Database: Supabase`);
  console.log(`📧 Email: ${config.email.user || 'Not configured'}`);
  console.log(`👮 Police Email: ${config.email.policeEmail}`);
});