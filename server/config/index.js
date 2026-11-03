const fs = require('fs');
const path = require('path');

const configPath = path.join(__dirname, 'config.env');

const config = {};

if (fs.existsSync(configPath)) {
  const configFile = fs.readFileSync(configPath, 'utf8');
  configFile.split('\n').forEach(line => {
    line = line.trim();
    if (line && !line.startsWith('#') && line.includes('=')) {
      const [key, ...valueParts] = line.split('=');
      const value = valueParts.join('=').trim();
      if (key && value) {
        config[key.trim()] = value.trim();
      }
    }
  });
} else {
  console.warn('⚠️ config.env not found, falling back to process.env');
}

const db = {
  connectionString: config.DATABASE_URL || process.env.DATABASE_URL || '',
  ssl: config.DB_SSL !== 'false' && (process.env.DB_SSL !== 'false')
};

const configuredJwtSecret = config.JWT_SECRET || process.env.JWT_SECRET || '';
const explicitDevMode = process.env.NODE_ENV === 'development' || process.env.NODE_ENV === 'test';

// Fail closed. The old guard only fired when NODE_ENV was exactly
// "production", so a deployment that forgot to set NODE_ENV silently ran with
// the default secret below. Now the default is only reachable in an explicit
// development/test run (npm run dev sets NODE_ENV=development via nodemon.json).
if (!configuredJwtSecret && !explicitDevMode) {
  throw new Error(
    'FATAL: JWT_SECRET is not set. Refusing to start with the development default secret. ' +
    'Set JWT_SECRET, or run local development with NODE_ENV=development (npm run dev).'
  );
}

const jwt = {
  secret: configuredJwtSecret || 'women-safety-guardian-secret-key-2024'
};

const email = {
  host: config.EMAIL_HOST || process.env.EMAIL_HOST || 'smtp.gmail.com',
  port: config.EMAIL_PORT || process.env.EMAIL_PORT || 587,
  user: config.EMAIL_USER || process.env.EMAIL_USER || '',
  pass: config.EMAIL_PASS || process.env.EMAIL_PASS || '',
  sendgridApiKey: config.SENDGRID_API_KEY || process.env.SENDGRID_API_KEY || '',
  brevoApiKey: config.BREVO_API_KEY || process.env.BREVO_API_KEY || '',
  brevoSenderEmail: config.BREVO_SENDER_EMAIL || process.env.BREVO_SENDER_EMAIL || '',
  brevoSenderName: config.BREVO_SENDER_NAME || process.env.BREVO_SENDER_NAME || 'ZELDA',
  smtpEnabled: (config.EMAIL_SMTP_ENABLED || process.env.EMAIL_SMTP_ENABLED || 'false') === 'true',
  from: config.EMAIL_FROM || process.env.EMAIL_FROM || 'Women Safety Guardian <noreply@guaridan.com>',
  policeEmail: config.POLICE_EMAIL || process.env.POLICE_EMAIL || 'police@guardian.com'
};

const supabase = {
  url: config.SUPABASE_URL || process.env.SUPABASE_URL || '',
  serviceRoleKey: config.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY || '',
  anonKey: config.SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY || process.env.SUPABASE_KEY || ''
};

const b2 = {
  keyId: config.B2_KEY_ID || process.env.B2_KEY_ID
    || config.B2_APPLICATION_KEY_ID || process.env.B2_APPLICATION_KEY_ID || '',
  applicationKey: config.B2_APPLICATION_KEY || process.env.B2_APPLICATION_KEY || '',
  bucket: config.B2_BUCKET || process.env.B2_BUCKET || 'zelda-evidence',
  region: config.B2_REGION || process.env.B2_REGION || '',
  endpoint: config.B2_ENDPOINT || process.env.B2_ENDPOINT || '',
  publicBaseUrl: config.B2_PUBLIC_BASE_URL || process.env.B2_PUBLIC_BASE_URL || ''
};

const r2 = {
  accountId: config.R2_ACCOUNT_ID || process.env.R2_ACCOUNT_ID || '',
  accessKeyId: config.R2_ACCESS_KEY_ID || process.env.R2_ACCESS_KEY_ID || '',
  secretAccessKey: config.R2_SECRET_ACCESS_KEY || process.env.R2_SECRET_ACCESS_KEY || '',
  bucket: config.R2_BUCKET || process.env.R2_BUCKET || 'sos-media',
  publicBaseUrl: config.R2_PUBLIC_BASE_URL || process.env.R2_PUBLIC_BASE_URL || '',
  endpoint: config.R2_ENDPOINT || process.env.R2_ENDPOINT || ''
};

const server = {
  port: config.PORT || process.env.PORT || 5000
};

const policeStation = {
  enabled: config.POLICE_STATION_ENABLED ?? process.env.POLICE_STATION_ENABLED ?? 'true',
  radiusM: config.POLICE_STATION_RADIUS_M || process.env.POLICE_STATION_RADIUS_M || '5000',
  overpassUrl: config.POLICE_STATION_OVERPASS_URL || process.env.POLICE_STATION_OVERPASS_URL || 'https://overpass-api.de/api/interpreter',
  timeoutMs: config.POLICE_STATION_TIMEOUT_MS || process.env.POLICE_STATION_TIMEOUT_MS || '3500'
};

const client = {
  url: config.CLIENT_URL || process.env.CLIENT_URL || 'http://localhost:3000',
  apiUrl: config.API_URL || process.env.API_URL || 'http://localhost:5000'
};

const validateConfig = () => {
  const required = [];
  const warnings = [];

  if (!db.connectionString) {
    warnings.push('DATABASE_URL not configured - falling back to process.env');
  }

  const b2Requested = !!(b2.keyId || b2.applicationKey || b2.region || b2.endpoint);
  if (b2Requested && (!b2.keyId || !b2.applicationKey || !b2.bucket || (!b2.region && !b2.endpoint))) {
    warnings.push('Backblaze B2 is partially configured - set B2_KEY_ID, B2_APPLICATION_KEY, B2_BUCKET and B2_REGION (or B2_ENDPOINT)');
  }

  if (!b2Requested && (!supabase.url || (!supabase.serviceRoleKey && !supabase.anonKey))) {
    warnings.push('No object storage fully configured - set B2, R2, or Supabase for media uploads');
  }

  if (!configuredJwtSecret) {
    warnings.push('JWT secret not configured — using the development-only default (NODE_ENV=development/test)');
  }

  if (!email.user || !email.pass) {
    warnings.push('Email not configured - SOS alerts will not be sent');
  }

  warnings.forEach(w => console.warn(`⚠️ ${w}`));

  if (required.length > 0) {
    console.error(`❌ Missing required config: ${required.join(', ')}`);
    process.exit(1);
  }
};

validateConfig();

module.exports = {
  config,
  db,
  supabase,
  b2,
  r2,
  jwt,
  email,
  server,
  client,
  policeStation
};