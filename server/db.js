const { Pool } = require('pg');
const config = require('./config');

if (!config.db.connectionString) {
  console.error('❌ DATABASE_URL is empty! Set it in server/config/config.env or Render → Environment → DATABASE_URL');
  console.error('   Expected: postgres://user:pass@host:5432/db?sslmode=require  (Supabase pooled connection string)');
}

const pool = new Pool({
  connectionString: config.db.connectionString || 'postgresql://invalid:invalid@localhost:5432/invalid',
  ssl: config.db.ssl ? { rejectUnauthorized: false } : false,
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 8000,
});

// Surface idle client errors (otherwise swallowed)
pool.on('error', (err) => {
  console.error('❌ PG Pool idle error:', err.message, err.code || '');
});

const query = async (sql, params = []) => {
  if (!config.db.connectionString) {
    const err = new Error('DATABASE_URL not configured');
    err.code = 'NO_DATABASE_URL';
    throw err;
  }
  try {
    const result = await pool.query(sql, params);
    return result.rows;
  } catch (err) {
    // Enrich log — Render logs will now show the real cause
    console.error('❌ DB query failed:', err.code || '', err.message);
    if (err.stack) console.error(err.stack.split('\n').slice(0, 4).join('\n'));
    throw err;
  }
};

const auditLog = async (userId, caseId, action, details) => {
  try {
    await query(
      'INSERT INTO audit_log (user_id, case_id, action, details, created_at) VALUES ($1, $2, $3, $4, now())',
      [userId || null, caseId || null, action, details || '']
    );
  } catch (error) {
    console.error('Audit log error:', error);
  }
};

module.exports = { pool, query, auditLog };
