/**
 * policeStationRouter — free, key-less turn-by-turn routing.
 *
 * Primary:  Valhalla  (valhalla1.openstreetmap.de)  -> ready-made instructions
 * Fallback: OSRM      (router.project-osrm.org)     -> GeoJSON + step list
 * Last:     OSRM-DE   (routing.openstreetmap.de)    -> same API, other operator
 *
 * Plus the OSRM *table* service for real road-distance matrices, so the
 * "nearest" station can be chosen by ROAD distance rather than by a
 * straight line (they are frequently different).
 *
 * No API keys, no billing, no quotas. Everything is cached by the caller.
 */

const https = require('https');
const { URL } = require('url');

const VALHALLA = 'https://valhalla1.openstreetmap.de/route';
const OSRM = 'https://router.project-osrm.org/route/v1/driving';
const OSRM_FALLBACK = 'https://routing.openstreetmap.de/routed-car/route/v1/driving';
const OSRM_TABLE = 'https://router.project-osrm.org/table/v1/driving';
const OSRM_TABLE_FALLBACK = 'https://routing.openstreetmap.de/routed-car/table/v1/driving';

const UA = 'Zelda-Guardian-TN/1.0 (public safety app)';

/* ----------------------------------------------------------------- http */
function fetchJson(url, { method = 'GET', body = null, timeoutMs = 25000 } = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request(
      {
        method,
        hostname: u.hostname,
        port: u.port || 443,
        path: u.pathname + u.search,
        headers: Object.assign(
          { 'User-Agent': UA, Accept: 'application/json' },
          body ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } : {}
        ),
        timeout: timeoutMs,
      },
      (res) => {
        let data = '';
        res.setEncoding('utf8');
        res.on('data', (c) => { data += c; });
        res.on('end', () => {
          if (res.statusCode < 200 || res.statusCode >= 300) {
            return reject(new Error(`upstream ${res.statusCode} for ${u.hostname}: ${data.slice(0, 200)}`));
          }
          try { resolve(JSON.parse(data)); } catch (e) { reject(new Error('routing JSON parse failed')); }
        });
      }
    );
    req.on('timeout', () => { req.destroy(new Error('routing timeout')); });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

/* ------------------------------------------------------------- polyline */
/** Decode a Google/Valhalla encoded polyline into [lat, lng] pairs. */
function decodePolyline(str, precision = 6) {
  const factor = Math.pow(10, precision);
  const out = [];
  let i = 0, lat = 0, lng = 0;
  while (i < str.length) {
    let b, shift = 0, res = 0;
    do { b = str.charCodeAt(i++) - 63; res |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
    lat += (res & 1) ? ~(res >> 1) : (res >> 1);
    shift = 0; res = 0;
    do { b = str.charCodeAt(i++) - 63; res |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
    lng += (res & 1) ? ~(res >> 1) : (res >> 1);
    out.push([lat / factor, lng / factor]);
  }
  return out;
}

/* ------------------------------------------------------------- geometry */
/** Great-circle distance in metres. */
function distanceM(a, b) {
  const R = 6371000, toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat), dLng = toRad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

/* --------------------------------------------------------------- steps  */
function iconFor(instruction, type) {
  const s = String(instruction || '').toLowerCase();
  if (/arrive|destination/.test(s) || type === 4 || type === 5 || type === 6) return 'arrive';
  if (/roundabout/.test(s) || type === 12 || type === 13) return 'roundabout';
  if (/u-?turn|turn around/.test(s) || type === 14) return 'uturn';
  if (/merge/.test(s)) return 'merge';
  if (/left/.test(s)) return 'left';
  if (/right/.test(s)) return 'right';
  if (/walk/.test(s)) return 'walk';
  if (type === 1 || type === 2 || type === 3) return 'start';
  return 'straight';
}

/* ------------------------------------------------------------ valhalla  */
async function routeValhalla(from, to, mode, lang) {
  const costing = mode === 'walk' ? 'pedestrian' : (mode === 'bike' ? 'bicycle' : 'auto');
  const body = {
    locations: [{ lat: from.lat, lon: from.lng }, { lat: to.lat, lon: to.lng }],
    costing,
    directions_options: { units: 'kilometers', language: lang || 'en-US' },
  };
  const j = await fetchJson(VALHALLA + '?json=' + encodeURIComponent(JSON.stringify(body)));
  if (!j || !j.trip || j.trip.status !== 0) throw new Error('valhalla: ' + (j && j.error));
  const leg = j.trip.legs[0];
  const shape = j.trip.shape || (leg && leg.shape) || '';
  const steps = (leg.maneuvers || []).map((m) => ({
    type: iconFor(m.instruction, m.type),
    instruction: m.instruction || '',
    street: m.street_names || '',
    distance: Math.round(m.length || 0),
    time: Math.round(m.time || 0),
    lat: m.lat,
    lng: m.lon,
  }));
  return {
    source: 'valhalla',
    distance: Math.round((j.trip.summary.length || 0) * 1000),
    duration: Math.round(j.trip.summary.time || 0),
    geometry: shape ? decodePolyline(shape, 6) : [],
    steps,
  };
}

/* ---------------------------------------------------------------- osrm  */
async function routeOSRM(from, to, base) {
  const url = base + '/' + from.lng + ',' + from.lat + ';' + to.lng + ',' + to.lat +
    '?overview=full&geometries=geojson&steps=true';
  const j = await fetchJson(url);
  const r = j && j.routes && j.routes[0];
  if (!r) throw new Error('osrm: no route');
  const steps = [];
  (r.legs || []).forEach((leg) => (leg.steps || []).forEach((s) => {
    const m = s.maneuver || {};
    const t = m.type;
    const instr = t === 'depart' ? 'Head ' + (m.modifier || 'out')
      : t === 'arrive' ? 'You have arrived'
      : t === 'turn' ? 'Turn ' + (m.modifier || '') + (s.name ? ' onto ' + s.name : '')
      : t === 'continue' ? 'Continue onto ' + (s.name || 'the road')
      : t === 'roundabout' ? 'Enter the roundabout and take the ' + (m.modifier || '') + ' exit'
      : t === 'merge' ? 'Merge onto ' + (s.name || 'the road')
      : t === 'new name' ? 'Continue onto ' + (s.name || 'the road')
      : (s.name || 'Continue');
    steps.push({
      type: iconFor(instr, t === 'arrive' ? 4 : 0),
      instruction: instr.charAt(0).toUpperCase() + instr.slice(1),
      street: s.name || '',
      distance: Math.round(s.distance || 0),
      time: Math.round(s.duration || 0),
      lat: m.location ? m.location[1] : null,
      lng: m.location ? m.location[0] : null,
    });
  }));
  return {
    source: 'osrm',
    distance: Math.round(r.distance || 0),
    duration: Math.round(r.duration || 0),
    geometry: (r.geometry && r.geometry.coordinates || []).map((c) => [c[1], c[0]]),
    steps,
  };
}

/** Route with the full fallback chain. */
async function route(from, to, mode, lang) {
  try { return await routeValhalla(from, to, mode, lang); } catch (e1) {
    try { return await routeOSRM(from, to, OSRM); } catch (e2) {
      return await routeOSRM(from, to, OSRM_FALLBACK);
    }
  }
}

/* ------------------------------------------------------- road distance  */
/**
 * Road distance from one source to many candidates, in ONE request.
 * Returns [distanceTo0, distanceTo1, ...] in metres, or null on failure.
 */
async function roadDistanceMatrix(from, points) {
  const coords = [from].concat(points).map((p) => `${p.lng},${p.lat}`).join(';');
  const tryUrl = async (base) => {
    const j = await fetchJson(base + '/' + coords + '?sources=0&annotations=distance');
    if (!j || !j.distances || !j.distances[0]) throw new Error('table: no matrix');
    return j.distances[0];
  };
  try { return await tryUrl(OSRM_TABLE); }
  catch (e) { return await tryUrl(OSRM_TABLE_FALLBACK); }
}

module.exports = {
  route,
  routeValhalla,
  routeOSRM,
  roadDistanceMatrix,
  decodePolyline,
  distanceM,
  VALHALLA,
  OSRM,
  OSRM_FALLBACK,
};
