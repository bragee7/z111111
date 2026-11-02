/**
 * build_offline_assets.js
 *
 * Produces the bundled assets that let the ZELDA mobile app work with
 * NO server at all (offline), and with no per-request backend calls (online):
 *
 *   1. tn_stations.json.gz   — the full Tamil Nadu police-station directory
 *                              (1,317 stations, 46 districts) with addresses,
 *                              phone numbers and coordinates.
 *   2. tn_helplines.json.gz  — the 46 district control-room numbers.
 *   3. tn_roads.bin.gz       — a compact routing graph built from the OSM road
 *                              network, so turn-by-turn routing + the true
 *                              shortest road distance work ON DEVICE.
 *
 * Run:  node server/tools/build_offline_assets.js
 */

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const https = require('https');

const OUT_DIR = path.join(__dirname, '..', '..', 'mobile', 'assets');
const ERSS = 'https://tn.erss.in/public/api/SOS_MEAP/';
const OVERPASS = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
];

// Tamil Nadu bounding box (inclusive), a touch wider than the state.
const TN = { latMin: 7.95, latMax: 13.62, lngMin: 76.10, lngMax: 80.65 };

// Road classes usable for car routing.
const CAR_ROADS = [
  'motorway', 'trunk', 'primary', 'secondary', 'tertiary', 'unclassified',
  'residential', 'living_street', 'service', 'motorway_link', 'trunk_link',
  'primary_link', 'secondary_link', 'tertiary_link', 'road',
];

const UA = 'Zelda-Guardian-Offline-Graph/1.0 (Tamil Nadu police app)';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function postJson(url, json, timeoutMs = 45000) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request(
      { method: 'POST', hostname: u.hostname, path: u.pathname + u.search,
        headers: { 'User-Agent': UA, 'Content-Type': 'application/json',
                   'Content-Length': Buffer.byteLength(json) }, timeout: timeoutMs },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          if (res.statusCode !== 200) {
            return reject(new Error(`HTTP ${res.statusCode} ` +
              Buffer.concat(chunks).toString('utf8').slice(0, 200)));
          }
          try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
          catch (e) { reject(new Error('bad json')); }
        });
      }
    );
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.write(json);
    req.end();
  });
}

function getJson(url, timeoutMs = 60000) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request(
      { method: 'GET', hostname: u.hostname, path: u.pathname + u.search,
        headers: { 'User-Agent': UA, Accept: 'application/json' }, timeout: timeoutMs },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
          catch (e) { reject(new Error('bad json')); }
        });
      }
    );
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.end();
  });
}

function postForm(url, body, timeoutMs = 600000) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request(
      { method: 'POST', hostname: u.hostname, path: u.pathname + u.search,
        headers: { 'User-Agent': UA, 'Content-Type': 'application/x-www-form-urlencoded',
                   'Content-Length': Buffer.byteLength(body) }, timeout: timeoutMs },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const b = Buffer.concat(chunks);
          if (res.statusCode !== 200) {
            return reject(new Error(`HTTP ${res.statusCode} ${b.toString('utf8').slice(0, 250)}`));
          }
          try { resolve(JSON.parse(b.toString('utf8'))); } catch (e) { reject(new Error('bad json')); }
        });
      }
    );
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

/* ------------------------------------------------------- ERSS directory */
async function buildDirectory() {
  console.log('[1/3] fetching station directory from ERSS ...');
  const list = await getJson(ERSS + 'police-station-list');
  const flat = [];
  for (const city of (list || [])) {
    for (const st of (city.station || [])) {
      flat.push({ i: String(st.stationId || ''), n: st.stationName || 'Police Station', d: city.cityName || 'Unknown' });
    }
  }
  const districts = new Set(flat.map((s) => s.d));
  console.log(`      ${flat.length} stations / ${districts.size} districts`);

  // Full details come from the locator, which is radius-based -> sweep the state.
  const details = new Map();
  const seeds = [];
  for (let lat = TN.latMin + 0.5; lat < TN.latMax; lat += 0.8) {
    for (let lng = TN.lngMin + 0.5; lng < TN.lngMax; lng += 0.8) seeds.push([lat, lng]);
  }
  console.log(`      sweeping ${seeds.length} probe points for full details ...`);

  const q = seeds.slice();
  const probed = [];
  let n = 0;
  while (q.length && n < 300) {
    const pt = q.shift();
    if (probed.some((p) => Math.hypot(p[0] - pt[0], p[1] - pt[1]) < 0.15)) continue;
    probed.push(pt);
    n++;
    let j = null;
    for (let a = 0; a < 3; a++) {
      try { j = await postJson(ERSS + 'police-station-locator', JSON.stringify({ lat: String(pt[0]), lng: String(pt[1]) })); break; }
      catch (e) { await sleep(1200 * (a + 1)); }
    }
    if (!j || !j.stationlist) continue;
    for (const s of j.stationlist) {
      const key = (s.stationname || '').toLowerCase() + '|' + (s.stationdistrict || '').toLowerCase();
      if (!details.has(key)) details.set(key, s);
      const la = parseFloat(s.stationlat), ln = parseFloat(s.stationlng);
      if (isFinite(la) && isFinite(ln)) {
        const p = [la, ln];
        if (!probed.some((z) => Math.hypot(z[0] - p[0], z[1] - p[1]) < 0.18)) q.push(p);
      }
    }
    if (n % 25 === 0) { console.log(`      probe ${n}: ${details.size} detailed, ${q.length} queued`); await sleep(200); }
  }
  console.log(`      ${details.size} detailed after ${n} probes`);

  const stations = flat.map((s) => {
    const det = details.get(s.n.toLowerCase() + '|' + s.d.toLowerCase());
    return {
      id: s.i, name: s.n, district: s.d,
      city: det ? det.stationcity : null,
      address: det ? det.stationaddress : null,
      phone: det ? det.stationphoneno : null,
      lat: det ? parseFloat(det.stationlat) : null,
      lng: det ? parseFloat(det.stationlng) : null,
    };
  });
  return stations;
}

/* ------------------------------------------------------ OSM road graph */
function overpassQuery(classes, latMin, latMax, lngMin, lngMax) {
  const cl = classes.map((c) => `"${c}"`).join('|');
  return `[out:json][timeout:900];way["highway"~"^(${cl})$"](${latMin},${lngMin},${latMax},${lngMax});out geom;`;
}

async function fetchOverpass(query) {
  const body = 'data=' + encodeURIComponent(query);
  for (const host of OVERPASS) {
    try {
      console.log(`      trying ${host} ...`);
      return await postForm(host, body, 900000);
    } catch (e) {
      console.log(`      ${host} failed: ${e.message}`);
      await sleep(5000);
    }
  }
  throw new Error('all overpass mirrors failed');
}

async function buildRoadGraph() {
  console.log('[2/3] building the OSM road graph for Tamil Nadu ...');
  const ways = [];
  const seenWays = new Set();
  const BAND = 0.5;
  for (let lat = TN.latMin; lat < TN.latMax; lat += BAND) {
    const latMax = Math.min(lat + BAND, TN.latMax);
    let j = null;
    try {
      j = await fetchOverpass(overpassQuery(CAR_ROADS, lat, latMax, TN.lngMin, TN.lngMax));
    } catch (e) {
      console.log(`      band ${lat.toFixed(2)} failed: ${e.message}`);
      continue;
    }
    let added = 0;
    for (const w of j.elements || []) {
      if (seenWays.has(w.id)) continue;
      seenWays.add(w.id);
      ways.push(w);
      added++;
    }
    console.log(`      band ${lat.toFixed(2)}-${latMax.toFixed(2)}: +${added} ways (total ${ways.length})`);
    await sleep(3000);
  }

  const nodeIndex = new Map();
  const nodes = [];
  const edges = [];
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const nodeId = (lat, lng) => {
    const key = lat.toFixed(6) + ',' + lng.toFixed(6);
    let id = nodeIndex.get(key);
    if (id === undefined) { id = nodes.length; nodeIndex.set(key, id); nodes.push([lat, lng]); }
    return id;
  };

  for (const w of ways) {
    const g = w.geometry;
    if (!g || g.length < 2) continue;
    const name = (w.tags && (w.tags.name || w.tags['name:en'] || w.tags.ref)) || '';
    const highway = (w.tags && w.tags.highway) || '';
    for (let i = 0; i < g.length - 1; i++) {
      const a = g[i], b = g[i + 1];
      const dLat = toRad(b.lat - a.lat), dLng = toRad(b.lng - a.lng);
      const x = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
      const dist = 2 * R * Math.asin(Math.sqrt(x));
      if (dist < 0.5) continue;
      edges.push([nodeId(a.lat, a.lng), nodeId(b.lat, b.lng), dist, name, highway]);
    }
  }
  console.log(`      graph: ${nodes.length} nodes, ${edges.length} edges`);

  // Binary layout (little-endian):
  //   header  : magic "TNGR" | version | nodeCount | edgeCount | nameCount
  //   nodes   : lat i32 (deg*1e6), lng i32 (deg*1e6)
  //   edges   : a u32 | b u32 | dist u32 (cm) | nameIdx u32 | class u8
  //   names   : per name: u16 len + utf8 bytes
  const roadClasses = [...new Set(edges.map((e) => e[4]))].sort();
  const classIdx = new Map(roadClasses.map((c, i) => [c, i]));
  const nameList = [...new Set(edges.map((e) => e[3]).filter(Boolean))].sort();
  const nameIdx = new Map(nameList.map((n, i) => [n, i]));

  const nameBytes = [];
  for (const n of nameList) {
    const b = Buffer.from(n, 'utf8');
    const len = Buffer.alloc(2); len.writeUInt16LE(b.length, 0);
    nameBytes.push(len, b);
  }

  const header = Buffer.alloc(20);
  header.write('TNGR', 0, 'ascii');
  header.writeUInt32LE(1, 4);
  header.writeUInt32LE(nodes.length, 8);
  header.writeUInt32LE(edges.length, 12);
  header.writeUInt32LE(nameList.length, 16);

  const nodeBuf = Buffer.alloc(nodes.length * 8);
  nodes.forEach((n, i) => {
    nodeBuf.writeInt32LE(Math.round(n[0] * 1e6), i * 8);
    nodeBuf.writeInt32LE(Math.round(n[1] * 1e6), i * 8 + 4);
  });

  const edgeBuf = Buffer.alloc(edges.length * 17);
  edges.forEach((e, i) => {
    const o = i * 17;
    edgeBuf.writeUInt32LE(e[0], o);
    edgeBuf.writeUInt32LE(e[1], o + 4);
    edgeBuf.writeUInt32LE(Math.round(e[2] * 100), o + 8);
    edgeBuf.writeUInt32LE(nameIdx.has(e[3]) ? nameIdx.get(e[3]) : 0xffffffff, o + 12);
    edgeBuf.writeUInt8(classIdx.get(e[4]) ?? 255, o + 16);
  });

  const raw = Buffer.concat([header, nodeBuf, edgeBuf, Buffer.concat(nameBytes)]);
  const gz = zlib.gzipSync(raw, { level: 9 });
  console.log(`      raw ${(raw.length / 1048576).toFixed(1)} MB -> gzip ${(gz.length / 1048576).toFixed(1)} MB`);
  return { gz, stats: { nodes: nodes.length, edges: edges.length, rawBytes: raw.length, gzipBytes: gz.length, classes: roadClasses } };
}

function gzJson(obj) {
  return zlib.gzipSync(Buffer.from(JSON.stringify(obj), 'utf8'), { level: 9 });
}

async function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });

  const stations = await buildDirectory();
  const stationsGz = gzJson({
    version: 1,
    source: 'ERSS / SOS_MEAP police-station-list + police-station-locator',
    generated: new Date().toISOString(),
    count: stations.length,
    stations,
  });
  fs.writeFileSync(path.join(OUT_DIR, 'tn_stations.json.gz'), stationsGz);
  console.log(`[1/3] tn_stations.json.gz  (${(stationsGz.length / 1024).toFixed(0)} KB, ${stations.length} stations)`);

  console.log('[2/3] fetching district helplines ...');
  const help = await getJson(ERSS + 'district-number-list');
  const helpGz = gzJson({
    version: 1,
    source: 'ERSS / SOS_MEAP district-number-list',
    generated: new Date().toISOString(),
    districts: (help.list || []).map((d) => ({ d: d.districtname, l1: d.landline1 || '', l2: d.landline2 || '', m: d.mobile || '' })),
  });
  fs.writeFileSync(path.join(OUT_DIR, 'tn_helplines.json.gz'), helpGz);
  console.log(`[2/3] tn_helplines.json.gz  (${(helpGz.length / 1024).toFixed(0)} KB, ${(help.list || []).length} districts)`);

  let roads;\n  try { roads = await buildRoadGraph(); }\n  catch (e) {\n    console.error('[3/3] road graph failed: ' + e.message + ' - keeping the placeholder graph');\n    const h = Buffer.alloc(20); h.write('TNGR', 0, 'ascii'); h.writeUInt32LE(1, 4);\n    h.writeUInt32LE(0, 8); h.writeUInt32LE(0, 12); h.writeUInt32LE(0, 16);\n    roads = { gz: zlib.gzipSync(h, { level: 9 }), stats: { nodes: 0, edges: 0, rawBytes: 20, gzipBytes: h.length, classes: [], placeholder: true } };\n  }
  fs.writeFileSync(path.join(OUT_DIR, 'tn_roads.bin.gz'), roads.gz);
  fs.writeFileSync(path.join(OUT_DIR, 'tn_roads.meta.json'), JSON.stringify({
    version: 1,
    source: 'OpenStreetMap via Overpass API (ODbL)',
    attribution: '(c) OpenStreetMap contributors',
    generated: new Date().toISOString(),
    ...roads.stats,
  }, null, 2));
  console.log(`[3/3] tn_roads.bin.gz  (${(roads.gz.length / 1048576).toFixed(1)} MB) + meta`);
  console.log('done.');
}

main().catch((e) => { console.error('FAILED:', e); process.exit(1); });
