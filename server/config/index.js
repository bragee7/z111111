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

const jwt = {
  secret: config.JWT_SECRET || process.env.JWT_SECRET || 'women-safety-guardian-secret-key-2024'
};

const email = {
  host: config.EMAIL_HOST || process.env.EMAIL_HOST || 'smtp.gmail.com',
  port: config.EMAIL_PORT || process.env.EMAIL_PORT || 587,
  user: config.EMAIL_USER || process.env.EMAIL_USER || '',
  pass: config.EMAIL_PASS || process.env.EMAIL_PASS || '',
  sendgridApiKey: config.SENDGRID_API_KEY || process.env.SENDGRID_API_KEY || '',
  from: config.EMAIL_FROM || process.env.EMAIL_FROM || 'Women Safety Guardian <noreply@guaridan.com>',
  policeEmail: config.POLICE_EMAIL || process.env.POLICE_EMAIL || 'police@guardian.com'
};

const supabase = {
  url: config.SUPABASE_URL || process.env.SUPABASE_URL || '',
  serviceRoleKey: config.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY || '',
  anonKey: config.SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY || process.env.SUPABASE_KEY || ''
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

  if (!supabase.url || (!supabase.serviceRoleKey && !supabase.anonKey)) {
    warnings.push('Supabase not fully configured - media uploads will be disabled');
  }

  if (!jwt.secret) {
    warnings.push('JWT secret not configured, using default');
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
  jwt,
  email,
  server,
  client,
  policeStation
};