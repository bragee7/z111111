// Browser-origin allow-list shared by Express and Socket.IO.
//
// Native mobile clients do not send an Origin header, so they are always
// allowed. Browsers are only allowed when they match the configured client
// URL, the API's own origin, a local dev server, or an explicit CORS_ORIGINS
// entry. Disallowed origins get no CORS headers (the request is not rejected
// with a 500), which is what browsers expect.
const { client } = require('./index');

const normalize = (origin) => String(origin || '').trim().replace(/\/+$/, '');

const extraOrigins = (process.env.CORS_ORIGINS || '')
  .split(',')
  .map(normalize)
  .filter(Boolean);

const allowedOrigins = [
  ...new Set(
    [
      client.url,
      client.apiUrl,
      'http://localhost:3000',
      'http://localhost:5173',
      'http://127.0.0.1:3000',
      'http://127.0.0.1:5173',
      ...extraOrigins
    ]
      .map(normalize)
      .filter(Boolean)
  )
];

const allowedSet = new Set(allowedOrigins);

const isAllowedOrigin = (origin) => {
  if (!origin) return true; // native app, curl, server-to-server
  return allowedSet.has(normalize(origin));
};

module.exports = { isAllowedOrigin, allowedOrigins };
