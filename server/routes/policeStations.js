/**
 * policeStations — Tamil Nadu police station directory + routing.
 *
 * Data source: the ERSS / SOS_MEAP backend used by the official
 * "Kaaval Uthavi" Android app:
 *   GET  /public/api/SOS_MEAP/police-station-list   (name + id, all districts)
 *   GET  /public/api/SOS_MEAP/district-number-list  (district helplines)
 *   GET  /public/api/SOS_MEAP/city-list
 *   POST /public/api/SOS_MEAP/police-station-locator {"lat":"..","lng":".."}
 *        -> full records (address, phone, lat/lng) for stations near a point
 *
 * The locator only returns stations inside a RADIUS, so a background sweep
 * ("hydrator") walks the whole state once and fills a detail pool. After that
 * every station has address / phone / coordinates and the app can sort by
 * real road distance.
 *
 * These routes are PUBLIC (directory data, no PII) so the mobile app can read
 * them before login.
 */

const express = require('express');
const https = require('https');
const { URL } = require('url');
const router = require('../services/policeStationRouter');

const routerExpr = express.Router();

const ERSS = 'https://tn.erss.in/public/api/SOS_MEAP/';
const UA = 'Zelda-Guardian-TN/1.0 (public safety app)';

/* ----------------------------------------------------------------- http */
function fetchUpstream(path, { method = 'GET', body = null, timeoutMs = 20000 } = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(ERSS + path);
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
            return reject(new Error(`ERSS ${res.statusCode}: ${data.slice(0, 200)}`));
          }
          try { resolve(JSON.parse(data)); } catch (e) { reject(new Error('ERSS JSON parse failed')); }
        });
      }
    );
    req.on('timeout', () => { req.destroy(new Error('ERSS timeout')); });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

/* ----------------------------------------------------------------- cache */
const cache = new Map();
async function cached(key, ttlMs, producer) {
  const hit = cache.get(key);
  const now = Date.now();
  if (hit && now - hit.at < ttlMs) return hit.value;
  try {
    const value = await producer();
    cache.set(key, { at: now, value });
    return value;
  } catch (err) {
    if (hit) return hit.value;        // stale-on-error fallback
    throw err;
  }
}
const TTL_LONG = 6 * 60 * 60 * 1000;   // 6h — static directory data
const TTL_SHORT = 60 * 1000;           // 1m — geo lookups

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* -------------------------------------------------------------- hydrate */
const detailPool = new Map();      // normalised name -> full record
const detailPoolMulti = new Map(); // normalised name -> [records]
const detailEpoch = new Map();     // "id|name" -> epoch when completed
let epoch = 0;

const hydrateState = {
  running: false, done: false, probes: 0, found: 0, total: 0,
  startedAt: null, finishedAt: null, error: null,
};

const norm = (s) => String(s == null ? '' : s)
  .toLowerCase().replace(/\s+/g, ' ').replace(/[^a-z0-9 ]/g, '').trim();

const SEED_POINTS = [
  [13.0827, 80.2707], [13.1147, 80.1088], [12.9229, 79.4550], [12.8342, 79.7036],
  [12.6819, 79.9888], [11.0168, 76.9558], [11.0141, 76.9558], [10.9601, 78.0766],
  [9.9252, 78.1198], [10.7870, 79.1378], [8.7139, 77.7567], [8.7642, 78.1348],
  [8.0883, 77.5385], [11.3410, 77.7172], [12.9165, 79.1325], [12.2253, 79.0747],
  [11.6643, 78.1460], [11.7789, 78.1460], [12.5266, 78.2141], [9.3639, 78.8395],
  [9.5680, 77.9620], [11.7480, 79.7714], [11.1401, 79.0782], [11.7389, 78.9570],
  [13.1871, 79.3714], [11.9280, 79.4500], [10.3624, 77.9695], [12.1211, 78.1583],
  [10.3833, 78.8001], [11.2189, 78.1677], [8.9594, 77.3152], [12.9249, 79.3308],
  [12.4996, 78.5678], [11.4064, 76.6932], [11.1018, 79.6555], [10.7660, 79.8420],
  [11.2342, 79.2058], [10.7905, 78.7047], [10.0104, 77.4777], [13.1231, 79.9120],
  [13.1283, 80.0751],
];

function degDist(a, b) {
  const dx = a[0] - b[0], dy = a[1] - b[1];
  return Math.sqrt(dx * dx + dy * dy);
}

async function hydrate() {
  if (hydrateState.running) return;
  hydrateState.running = true;
  hydrateState.done = false;
  hydrateState.error = null;
  hydrateState.startedAt = Date.now();
  hydrateState.probes = 0;
  detailPool.clear();
  detailPoolMulti.clear();
  detailEpoch.clear();
  epoch = 0;

  const probed = [];
  const queue = SEED_POINTS.slice();

  try {
    const raw = await getStationDirectory();
    hydrateState.total = raw.length;

    let guard = 0;
    while (queue.length && guard < 500) {
      guard++;
      const pt = queue.shift();
      if (probed.some((p) => degDist(p, pt) < 0.07)) continue;   // ~8 km covered
      probed.push(pt);
      hydrateState.probes++;

      let data;
      try {
        data = await fetchUpstream('police-station-locator', {
          method: 'POST',
          body: JSON.stringify({ lat: String(pt[0]), lng: String(pt[1]) }),
        });
      } catch (e) {
        await sleep(1200);
        continue;
      }
      const list = (data && data.stationlist) || [];
      for (const s of list) {
        const nk = norm(s.stationname);
        if (!nk) continue;
        if (!detailPool.has(nk)) {
          detailPool.set(nk, s);
          hydrateState.found++;
          epoch++;
        }
        if (!detailPoolMulti.has(nk)) detailPoolMulti.set(nk, []);
        const arr = detailPoolMulti.get(nk);
        if (!arr.some((x) => norm(x.stationdistrict) === norm(s.stationdistrict))) arr.push(s);

        const la = parseFloat(s.stationlat), ln = parseFloat(s.stationlng);
        if (isFinite(la) && isFinite(ln)) {
          const p = [la, ln];
          if (!probed.some((q) => degDist(q, p) < 0.10)) queue.push(p);
        }
      }
      await sleep(220);                    // be gentle with the public backend
    }
  } catch (err) {
    hydrateState.error = String(err && err.message ? err.message : err);
  }

  hydrateState.running = false;
  hydrateState.done = true;
  hydrateState.finishedAt = Date.now();
  console.log(`[police-stations] hydrate done — probes=${hydrateState.probes} detailed=${hydrateState.found}/${hydrateState.total} in ${Math.round((hydrateState.finishedAt - hydrateState.startedAt) / 1000)}s`);
}

/* ----------------------------------------------------------- directory  */
function flattenStations(raw) {
  const list = Array.isArray(raw) ? raw : (raw && raw.station_list) || [];
  const out = [];
  for (const city of list) {
    const district = city.cityName || city.cityname || city.district || 'Unknown';
    const cityId = city.cityId || city.cityid || '';
    for (const st of (city.station || city.stations || [])) {
      out.push({
        id: String(st.stationId || st.stationid || ''),
        name: st.stationName || st.stationname || 'Police Station',
        district,
        cityId: String(cityId),
      });
    }
  }
  return out;
}

async function getStationDirectory() {
  const raw = await cached('station-directory', TTL_LONG, () => fetchUpstream('police-station-list'));
  return flattenStations(raw);
}

function lookupDetail(s) {
  const nk = norm(s.name || s.stationname);
  const dk = norm(s.district || s.stationdistrict);
  const exact = detailPool.get(nk);
  if (exact) {
    if (!dk || !norm(exact.stationdistrict) || norm(exact.stationdistrict) === dk) return exact;
  }
  const multi = detailPoolMulti.get(nk);
  if (multi && multi.length) {
    const hit = multi.find((x) => norm(x.stationdistrict) === dk);
    if (hit) return hit;
    if (multi.length === 1) return multi[0];
  }
  return exact || null;
}

/** Full directory, merged with every detail we know. */
function mergedStations() {
  const raw = flattenStations(cache.get('station-directory') ? cache.get('station-directory').value : []);
  return raw.map((s) => {
    const full = lookupDetail(s);
    if (!full) return s;
    const key = s.id + '|' + s.name;
    if (!detailEpoch.has(key)) detailEpoch.set(key, epoch);
    return {
      id: s.id,
      name: s.name,
      district: s.district,
      cityId: s.cityId,
      stationname: full.stationname,
      stationcity: full.stationcity,
      stationdistrict: full.stationdistrict || s.district,
      stationaddress: full.stationaddress,
      stationphoneno: full.stationphoneno,
      stationlat: full.stationlat,
      stationlng: full.stationlng,
    };
  });
}

/* --------------------------------------------------------------- helpers */
function parsePoint(s) {
  if (!s) return null;
  const m = String(s).split(',').map(Number);
  if (m.length !== 2 || !isFinite(m[0]) || !isFinite(m[1])) return null;
  if (Math.abs(m[0]) > 90 || Math.abs(m[1]) > 180) return null;
  return { lat: m[0], lng: m[1] };
}

/* ---------------------------------------------------------------- routes */

/** GET /api/police-stations/list — the whole directory (1,300+ stations). */
routerExpr.get('/list', async (req, res) => {
  try {
    await getStationDirectory();
    const stations = mergedStations();
    if (!hydrateState.done && !hydrateState.running) hydrate();   // warm in the background
    res.json({
      total: stations.length,
      detailed: detailPool.size,
      epoch,
      stations,
    });
  } catch (err) {
    res.status(502).json({ error: 'Police station directory unavailable: ' + err.message });
  }
});

/** GET /api/police-stations/districts — district helpline numbers. */
routerExpr.get('/districts', async (req, res) => {
  try {
    const data = await cached('district-numbers', TTL_LONG, () => fetchUpstream('district-number-list'));
    res.json(data);
  } catch (err) {
    res.status(502).json({ error: 'District helplines unavailable: ' + err.message });
  }
});

/** GET /api/police-stations/cities — city list. */
routerExpr.get('/cities', async (req, res) => {
  try {
    const data = await cached('city-list', TTL_LONG, () => fetchUpstream('city-list'));
    res.json(data);
  } catch (err) {
    res.status(502).json({ error: 'City list unavailable: ' + err.message });
  }
});

/** POST /api/police-stations/nearby  { lat, lng } — stations near a point. */
routerExpr.post('/nearby', async (req, res) => {
  const lat = parseFloat(req.body && req.body.lat);
  const lng = parseFloat(req.body && req.body.lng);
  if (!isFinite(lat) || !isFinite(lng)) {
    return res.status(400).json({ error: 'lat and lng are required' });
  }
  try {
    const key = `nearby:${lat.toFixed(3)},${lng.toFixed(3)}`;
    const data = await cached(key, TTL_SHORT, () => fetchUpstream('police-station-locator', {
      method: 'POST',
      body: JSON.stringify({ lat: String(lat), lng: String(lng) }),
    }));
    res.json(data);
  } catch (err) {
    res.status(502).json({ error: 'Nearby lookup failed: ' + err.message });
  }
});

/** GET /api/police-stations/route?from=lat,lng&to=lat,lng&mode=auto|walk|bike */
routerExpr.get('/route', async (req, res) => {
  const from = parsePoint(req.query.from);
  const to = parsePoint(req.query.to);
  const mode = String(req.query.mode || 'auto').slice(0, 12);
  const lang = String(req.query.lang || 'en-US').slice(0, 10);
  if (!from || !to) {
    return res.status(400).json({ error: 'from=lat,lng and to=lat,lng are required' });
  }
  const key = `route:${from.lat.toFixed(5)},${from.lng.toFixed(5)}>${to.lat.toFixed(5)},${to.lng.toFixed(5)}:${mode}`;
  try {
    const data = await cached(key, 10 * 60 * 1000, () => router.route(from, to, mode, lang));
    res.json(data);
  } catch (err) {
    res.status(502).json({ error: 'Routing failed: ' + err.message });
  }
});

/**
 * GET /api/police-stations/nearest-route?from=lat,lng&k=10&mode=auto
 * Chooses the station with the SHORTEST ROAD distance (not the closest in a
 * straight line) and returns the full route to it.
 */
routerExpr.get('/nearest-route', async (req, res) => {
  const from = parsePoint(req.query.from);
  const mode = String(req.query.mode || 'auto').slice(0, 12);
  const lang = String(req.query.lang || 'en-US').slice(0, 10);
  const k = Math.max(1, Math.min(25, parseInt(req.query.k || '10', 10) || 10));
  if (!from) return res.status(400).json({ error: 'from=lat,lng is required' });

  try {
    await getStationDirectory();
    const all = mergedStations().filter((s) => isFinite(s.stationlat) && isFinite(s.stationlng));
    if (!all.length) return res.status(503).json({ error: 'Station directory not ready' });

    const byAir = all
      .map((s) => ({ s, air: router.distanceM(from, { lat: s.stationlat, lng: s.stationlng }) }))
      .sort((a, b) => a.air - b.air)
      .slice(0, k);

    let best = byAir[0];
    try {
      const matrix = await router.roadDistanceMatrix(
        from,
        byAir.map((c) => ({ lat: c.s.stationlat, lng: c.s.stationlng }))
      );
      let bestRoad = Infinity;
      byAir.forEach((c, i) => {
        const road = (matrix && matrix[i] != null) ? matrix[i] : c.air;
        c.road = road;
        if (road < bestRoad) { bestRoad = road; best = c; }
      });
    } catch (e) {
      byAir.forEach((c) => { c.road = c.air; });
    }

    const dest = { lat: best.s.stationlat, lng: best.s.stationlng };
    const key = `route:${from.lat.toFixed(5)},${from.lng.toFixed(5)}>${dest.lat.toFixed(5)},${dest.lng.toFixed(5)}:${mode}`;
    const data = await cached(key, 10 * 60 * 1000, () => router.route(from, dest, mode, lang));

    res.json({
      route: data,
      station: best.s,
      candidates: byAir.map((c) => ({
        stationId: c.s.id,
        name: c.s.name,
        district: c.s.district,
        air: Math.round(c.air),
        road: Math.round(c.road || c.air),
      })),
    });
  } catch (err) {
    res.status(502).json({ error: 'Nearest-route failed: ' + err.message });
  }
});

/** GET /api/police-stations/hydrate — sweep progress (for the app's progress bar). */
routerExpr.get('/hydrate', (req, res) => {
  res.json({
    running: hydrateState.running,
    done: hydrateState.done,
    probes: hydrateState.probes,
    found: hydrateState.found,
    total: hydrateState.total,
    epoch,
    error: hydrateState.error,
  });
});

module.exports = routerExpr;
module.exports.hydrate = hydrate;
module.exports.getStationDirectory = getStationDirectory;
module.exports.mergedStations = mergedStations;
