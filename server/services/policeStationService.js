/**
 * policeStationService — Tamil Nadu scoped nearest police station lookup.
 * Backend-only. Overpass API (OSM amenity=police). Fail-open: never blocks SOS.
 */

const https = require('https');

// Tamil Nadu approximate bounding box (inclusive)
const TN_BBOX = {
  latMin: 8.0,
  latMax: 13.6,
  lngMin: 76.1,
  lngMax: 80.6,
};

function isInsideTamilNadu(lat, lng) {
  return lat >= TN_BBOX.latMin && lat <= TN_BBOX.latMax
      && lng >= TN_BBOX.lngMin && lng <= TN_BBOX.lngMax;
}

function toRad(d) { return (d * Math.PI) / 180; }

/** Haversine distance in metres, pure — unit-testable. */
function distanceM(lat1, lng1, lat2, lng2) {
  const R = 6371000;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2
    + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

function getOverpassUrl() {
  try {
    const cfg = require('../config');
    return cfg.policeStation?.overpassUrl
        || process.env.POLICE_STATION_OVERPASS_URL
        || 'https://overpass-api.de/api/interpreter';
  } catch (_) {
    return process.env.POLICE_STATION_OVERPASS_URL
        || 'https://overpass-api.de/api/interpreter';
  }
}

function getTimeoutMs() {
  try {
    const cfg = require('../config');
    const v = cfg.policeStation?.timeoutMs ?? process.env.POLICE_STATION_TIMEOUT_MS;
    const n = parseInt(v, 10);
    return Number.isFinite(n) ? n : 3500;
  } catch (_) { return 3500; }
}

function getRadiusM() {
  try {
    const cfg = require('../config');
    const v = cfg.policeStation?.radiusM ?? process.env.POLICE_STATION_RADIUS_M;
    const n = parseInt(v, 10);
    return Number.isFinite(n) && n > 0 ? n : 5000;
  } catch (_) { return 5000; }
}

function isEnabled() {
  try {
    const cfg = require('../config');
    const v = cfg.policeStation?.enabled;
    if (typeof v === 'boolean') return v;
    if (typeof v === 'string') return v.toLowerCase() !== 'false';
  } catch (_) {}
  const env = process.env.POLICE_STATION_ENABLED;
  if (env != null) return String(env).toLowerCase() !== 'false';
  return true;
}

function buildOverpassQuery(lat, lng, radius) {
  // Nodes + ways + relations with amenity=police around radius; center for ways/relations
  return `[out:json][timeout:5];(node[\"amenity\"=\"police\"](around:${radius},${lat},${lng});way[\"amenity\"=\"police\"](around:${radius},${lat},${lng});relation[\"amenity\"=\"police\"](around:${radius},${lat},${lng}););out center meta;`;
}

function postOverpass(query, timeoutMs) {
  const url = new URL(getOverpassUrl());
  const body = Buffer.from(query, 'utf8');
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: url.hostname,
      path: url.pathname + url.search,
      method: 'POST',
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
        'Content-Length': body.length,
        'User-Agent': 'Zelda-Guardian-TN/1.0',
      },
      timeout: timeoutMs,
    }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        if (res.statusCode < 200 || res.statusCode >= 300) {
          return reject(new Error(`Overpass HTTP ${res.statusCode}: ${data.slice(0, 500)}`));
        }
        try { resolve(JSON.parse(data)); } catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(new Error(`Overpass timeout ${timeoutMs}ms`)); });
    req.write(body);
    req.end();
  });
}

function pickNearest(elements, originLat, originLng) {
  if (!elements || elements.length === 0) return null;
  let best = null;
  let bestDist = Infinity;
  for (const el of elements) {
    const lat = el.lat ?? el.center?.lat;
    const lon = el.lon ?? el.center?.lon;
    if (lat == null || lon == null) continue;
    const d = distanceM(originLat, originLng, lat, lon);
    if (d < bestDist) {
      bestDist = d;
      best = { el, lat, lon, dist: Math.round(d) };
    }
  }
  return best;
}

/**
 * Resolve nearest police station inside Tamil Nadu.
 * Returns null on any failure, bbox miss, or no result — never throws.
 * Shape (when found): { name, address, lat, lng, distanceM, osmId, osmType, fetchedAt }
 */
async function findNearestPoliceStation(lat, lng, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? getTimeoutMs();
  const radiusM = opts.radiusM ?? getRadiusM();
  try {
    if (!isEnabled()) return null;

    const nlat = Number(lat);
    const nlng = Number(lng);
    if (!Number.isFinite(nlat) || !Number.isFinite(nlng)) return null;

    // Tamil Nadu scope — outside state = null (caller stores NULL snapshot)
    if (!isInsideTamilNadu(nlat, nlng)) return null;

    const q = buildOverpassQuery(nlat, nlng, radiusM);
    const json = await postOverpass(q, timeoutMs);
    const best = pickNearest(json.elements, nlat, nlng);
    if (!best) return null;

    const tags = best.el.tags || {};
    const name = (tags.name || tags['name:en'] || tags['official_name'] || '').trim() || null;
    // OSM address is fragmented; join what exists — caller renders as-is
    const addrParts = [
      tags['addr:full'], tags['addr:street'], tags['addr:housenumber'],
      tags['addr:city'] || tags['addr:town'] || tags['addr:village'],
      tags['addr:district'], tags['addr:state'], tags['addr:postcode'],
    ].filter(Boolean);
    const address = addrParts.length ? addrParts.join(', ') : (tags.address || null);

    return {
      name: name || 'Police Station',
      address,
      lat: best.lat,
      lng: best.lon,
      distanceM: best.dist,
      osmId: best.el.id ?? null,
      osmType: best.el.type ?? null,
      fetchedAt: new Date().toISOString(),
    };
  } catch (err) {
    console.warn('[policeStation] lookup failed (SOS continues):', err.message);
    return null;
  }
}

module.exports = {
  TN_BBOX,
  isInsideTamilNadu,
  distanceM,
  buildOverpassQuery,
  findNearestPoliceStation,
};
