const fs = require('fs');
const path = require('path');

const config = require('../config');
const { pool } = require('../db');

const MIGRATIONS_DIR = path.join(__dirname, '..', 'sql', 'migrations');

// Arbitrary but stable key: serializes migration runs between instances.
const MIGRATION_LOCK_ID = 728193421;

const listMigrations = () => {
  if (!fs.existsSync(MIGRATIONS_DIR)) return [];
  return fs
    .readdirSync(MIGRATIONS_DIR)
    .filter((name) => name.endsWith('.sql'))
    .sort();
};

/**
 * Apply pending files from server/sql/migrations in filename order.
 *
 * Each file runs once and is recorded in `schema_migrations`. The whole set is
 * wrapped in one transaction guarded by a Postgres advisory lock, so a second
 * instance booting at the same time waits instead of racing the DDL. A failure
 * rolls back and is rethrown: the API must not serve traffic against a schema
 * it does not understand.
 */
const runMigrations = async ({ logger = console } = {}) => {
  if (process.env.SKIP_DB_MIGRATIONS === 'true') {
    logger.log('[migrate] skipped (SKIP_DB_MIGRATIONS=true)');
    return { applied: [], skipped: true };
  }
  if (!config.db.connectionString) {
    logger.warn('[migrate] DATABASE_URL not configured, skipping migrations');
    return { applied: [], skipped: true };
  }

  const files = listMigrations();
  if (files.length === 0) return { applied: [], skipped: false };

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock($1)', [MIGRATION_LOCK_ID]);
    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version TEXT PRIMARY KEY,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
      )
    `);

    const done = await client.query('SELECT version FROM schema_migrations');
    const appliedVersions = new Set(done.rows.map((row) => row.version));
    const applied = [];

    for (const file of files) {
      if (appliedVersions.has(file)) continue;
      const sql = fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8');
      logger.log(`[migrate] applying ${file}`);
      await client.query(sql);
      await client.query(
        'INSERT INTO schema_migrations (version) VALUES ($1)',
        [file]
      );
      applied.push(file);
    }

    await client.query('COMMIT');
    return { applied, skipped: false };
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw new Error(`database migration failed: ${error.message}`);
  } finally {
    client.release();
  }
};

module.exports = { runMigrations, listMigrations };
