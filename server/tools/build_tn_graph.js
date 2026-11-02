/* eslint-disable */
/**
 * Build the bundled, fully-offline Tamil Nadu road graph + place labels.
 *
 * Output (mobile/assets):
 *   tn_roads.bin.gz      TNG2 binary graph (nodes, edges, names, spatial grid)
 *   tn_roads.meta.json   human-readable summary
 *   tn_places.json.gz    city/town labels for the offline map
 *
 * Usage:  node build_tn_graph.js [--group=art|res|all] [--no-cache]
 *
 * Resumable: every Overpass response is cached in tools/osm-cache/ so a
 * failure never loses completed bands.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const https = require('https');

const ROOT = path.resolve(__dirname, '..', '..');
const ASSETS = path.join(ROOT, 'mobile', 'assets');
const CACHE = path.join(__dirname, 'osm-cache');
if (!fs.existsSync(CACHE)) fs.mkdirSync(CACHE, { recursive: true });
if (!fs.existsSync(ASSETS)) fs.mkdirSync(ASSETS, { recursive: true });

const BB = { latMin: 7.95, latMax: 13.62, lngMin: 76.1, lngMax: 80.65 };

const MIRRORS = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
];

const UA = 'Zelda-Guardian-OfflineMap/2.0 (offline bundle builder)';

// Road classes in routing/rendering priority order (index = class id).
const CLASSES = [
  'motorway', 'trunk', 'primary', 'secondary', 'tertiary',
  'unclassified', 'residential', 'living_street', 'service',
  'motorway_link', 'trunk_link', 'primary_link', 'secondary_link',
  'tertiary_link', 'road', 'track', 'path', 'footway', 'cycleway',
];
const CLASS_ID = new Map(CLASSES.map((c, i) => [c, i]));

// Groups: which classes to pull in each Overpass pass.
const GROUPS = {
  // Arterial network: every road that matters for getting to a town, plus the
  // district roads that carry traffic inside it. Excludes residential /
  // unclassified village lanes, which triple the size for little routing gain.
  art2: ['motorway', 'trunk', 'primary', 'secondary', 'tertiary',
    'motorway_link', 'trunk_link', 'primary_link', 'secondary_link',
    'tertiary_link', 'road'],
  art: ['motorway', 'trunk', 'primary', 'secondary', 'tertiary',
    'motorway_link', 'trunk_link', 'primary_link', 'secondary_link',
    'tertiary_link', 'unclassified', 'road'],
  res: ['residential', 'living_street', 'service', 'track', 'path', 'footway', 'cycleway'],
};

const args = process.argv.slice(2);
const groupArg = (args.find((a) => a.startsWith('--group=')) || '--group=art').split('=')[1];
const useCache = !args.includes('--no-cache');

const BAND = 0.35; // degrees latitude per request

function log(...a) { console.log(new Date().toISOString().slice(11, 19), ...a); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function post(url, body, timeoutMs = 150000) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request({
      method: 'POST',
      hostname: u.hostname,
      path: u.pathname + u.search,
      headers: {
        'User-Agent': UA,
        'Content-Type': 'application/x-www-form-urlencoded',
        'Content-Length': Buffer.byteLength(body),
        'Accept-Encoding': 'gzip',
      },
      timeout: timeoutMs,
    }, (res) => {
      const chunks = [];
      let stream = res;
      const enc = (res.headers['content-encoding'] || '').toLowerCase();
      if (enc === 'gzip') stream = res.pipe(zlib.createGunzip());
      stream.on('data', (d) => chunks.push(d));
      stream.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        if (res.statusCode !== 200) {
          return reject(new Error(`HTTP ${res.statusCode} ${text.slice(0, 220).replace(/\s+/g, ' ')}`));
        }
        try { resolve(JSON.parse(text)); } catch (e) { reject(new Error('bad json: ' + e.message)); }
      });
      stream.on('error', reject);
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

/** One Overpass request with mirror rotation + retries. */
async function overpass(query, cacheKey, altKeys = [], attempts = 18) {
  const candidates = [cacheKey, ...altKeys];
  for (const key of candidates) {
    const file = path.join(CACHE, key + '.json');
    if (useCache && fs.existsSync(file)) {
      try {
        const raw = fs.readFileSync(file, 'utf8');
        const j = JSON.parse(raw);
        log(`   cache hit ${key} (${(raw.length / 1048576).toFixed(1)} MB)`);
        return j;
      } catch (e) { /* fall through to re-download */ }
    }
  }
  const file = path.join(CACHE, cacheKey + '.json');
  const body = 'data=' + encodeURIComponent(query);
  for (let attempt = 0; attempt < attempts; attempt++) {
    const mirror = MIRRORS[attempt % MIRRORS.length];
    try {
      const t0 = Date.now();
      const j = await overpassOnce(mirror, body);
      const ms = Date.now() - t0;
      // Never cache an error payload.
      if (!j.elements) throw new Error('no elements');
      fs.writeFileSync(file, JSON.stringify(j));
      log(`   ${mirror.split('/')[2]} ok in ${(ms / 1000).toFixed(0)}s, `
        + `${j.elements.length} elements (${(fs.statSync(file).size / 1048576).toFixed(1)} MB)`);
      return j;
    } catch (e) {
      log(`   ${mirror.split('/')[2]} failed: ${(e.message || e.code || 'unknown').slice(0, 120)}`);
      await sleep(3000 + attempt * 3000);
    }
  }
  throw new Error('all mirrors failed for ' + cacheKey);
}

function overpassOnce(mirror, body) {
  return post(mirror, body);
}

function wayQuery(classes, latMin, latMax) {
  const re = '^(' + classes.join('|') + ')$';
  return `[out:json][timeout:180];`
    + `way["highway"~"${re}"](${latMin.toFixed(3)},${BB.lngMin},${latMax.toFixed(3)},${BB.lngMax});`
    + `out body;>;out skel qt;`;
}

/** Merge two Overpass results into one element list. */
function mergeResults(a, b) {
  return { elements: [...(a.elements || []), ...(b.elements || [])] };
}

/**
 * Fetch a lat band, splitting it in half when the request is too heavy for
 * the mirror to answer inside its gateway timeout.
 */
async function fetchBand(classes, a, b, depth = 0) {
  const key = `${groupArg}_${a.toFixed(2)}_${b.toFixed(2)}`;
  // Escalate quickly: a heavy band is split after only a couple of tries,
  // because the mirrors answer with a gateway timeout long before they give up.
  const attempts = depth === 0 ? 2 : (depth === 1 ? 3 : (depth === 2 ? 6 : 18));
  try {
    return await overpass(wayQuery(classes, a, b), key, [], attempts);
  } catch (e) {
    if (depth >= 4 || (b - a) < 0.04) {
      log(`   band ${a.toFixed(3)}..${b.toFixed(3)} gave up`);
      throw e;
    }
    const mid = (a + b) / 2;
    log(`   splitting band ${a.toFixed(2)}..${b.toFixed(2)} at ${mid.toFixed(3)}`);
    const j1 = await fetchBand(classes, a, mid, depth + 1);
    const j2 = await fetchBand(classes, mid, b, depth + 1);
    return mergeResults(j1, j2);
  }
}

// ---------------------------------------------------------------- graph build

async function buildGraph() {
  const classes = GROUPS[groupArg];
  if (!classes) throw new Error('unknown --group=' + groupArg);
  log(`group=${groupArg} classes=${classes.join(',')}`);

  const nodes = new Map();          // osmId -> [lat, lng]
  const ways = [];                  // { cls, oneway, name, refs[] }

  const bands = [];
  for (let lat = BB.latMin; lat < BB.latMax; lat += BAND) {
    bands.push([lat, Math.min(lat + BAND, BB.latMax)]);
  }
  log(`${bands.length} bands of ${BAND}deg`);

  for (let bi = 0; bi < bands.length; bi++) {
    const [a, b] = bands[bi];
    const key = `${groupArg}_${a.toFixed(2)}_${b.toFixed(2)}`;
    log(`band ${bi + 1}/${bands.length} lat ${a.toFixed(2)}..${b.toFixed(2)}`);
    let j;
    try {
      j = await fetchBand(classes, a, b);
    } catch (e) {
      log(`   band FAILED, continuing: ${e.message}`);
      continue;
    }
    let newWays = 0;
    for (const el of j.elements) {
      if (el.type === 'node') {
        if (!nodes.has(el.id)) nodes.set(el.id, [el.lat, el.lon]);
      } else if (el.type === 'way' && el.nodes && el.nodes.length >= 2) {
        const t = el.tags || {};
        const hw = t.highway || '';
        const cls = CLASS_ID.has(hw) ? CLASS_ID.get(hw) : 14;
        let oneway = 0;
        const ow = (t.oneway || '').toLowerCase();
        if (ow === 'yes' || ow === 'true' || ow === '1' || t.junction === 'roundabout' || t.junction === 'circular') oneway = 1;
        else if (ow === '-1' || ow === 'reverse') oneway = 2;
        const name = t.name || t['name:en'] || t.ref || '';
        ways.push({ cls, oneway, name, refs: el.nodes });
        newWays++;
      }
    }
    log(`   +${newWays} ways (total ${ways.length}), ${nodes.size} nodes seen`);
    await sleep(8000);
  }

  // ---- index nodes
  const nodeIds = new Map();        // osmId -> dense index (only for used nodes)
  const latArr = [];
  const lngArr = [];
  for (const w of ways) {
    for (const id of w.refs) {
      if (nodeIds.has(id)) continue;
      const c = nodes.get(id);
      if (!c) continue;
      nodeIds.set(id, latArr.length);
      latArr.push(Math.round(c[0] * 1e6));
      lngArr.push(Math.round(c[1] * 1e6));
    }
  }
  const nodeCount = latArr.length;
  log(`graph nodes: ${nodeCount}`);

  // ---- names table
  const nameList = [];
  const nameIdx = new Map();
  for (const w of ways) {
    if (!w.name) continue;
    if (!nameIdx.has(w.name)) { nameIdx.set(w.name, nameList.length); nameList.push(w.name); }
  }
  const NONE = 0xffffffff;

  // ---- edges (one per consecutive node pair, both directions handled by flags)
  const ea = [];
  const eb = [];
  const em = [];
  const en = [];
  const ec = [];
  const ef = [];
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const hav = (la1, lo1, la2, lo2) => {
    const dLat = toRad(la2 - la1);
    const dLng = toRad(lo2 - lo1);
    const x = Math.sin(dLat / 2) ** 2
      + Math.cos(toRad(la1)) * Math.cos(toRad(la2)) * Math.sin(dLng / 2) ** 2;
    return 2 * R * Math.asin(Math.min(1, Math.sqrt(x)));
  };

  let merged = 0;
  for (const w of ways) {
    const ni = nameIdx.has(w.name) ? nameIdx.get(w.name) : NONE;
    for (let i = 0; i < w.refs.length - 1; i++) {
      const u = nodeIds.get(w.refs[i]);
      const v = nodeIds.get(w.refs[i + 1]);
      if (u === undefined || v === undefined || u === v) continue;
      const la1 = latArr[u] / 1e6, lo1 = lngArr[u] / 1e6;
      const la2 = latArr[v] / 1e6, lo2 = lngArr[v] / 1e6;
      let d = hav(la1, lo1, la2, lo2);
      if (d < 0.5) { merged++; continue; }
      if (d > 65535) d = 65535;
      ea.push(u); eb.push(v); em.push(Math.round(d)); en.push(ni); ec.push(w.cls); ef.push(w.oneway);
    }
  }
  const edgeCount = ea.length;
  log(`graph edges: ${edgeCount} (skipped ${merged} zero-length)`);

  // ---- spatial grid over edges (for the offline map renderer)
  const GX = 128;
  const GY = 128;
  const cellCount = GX * GY;
  const cellStart = new Uint32Array(cellCount + 1);
  const cellOf = new Int32Array(edgeCount);
  const dLng = (BB.lngMax - BB.lngMin) / GX;
  const dLat = (BB.latMax - BB.latMin) / GY;
  for (let i = 0; i < edgeCount; i++) {
    const la = (latArr[ea[i]] + latArr[eb[i]]) / 2e6;
    const lo = (lngArr[ea[i]] + lngArr[eb[i]]) / 2e6;
    let cx = Math.floor((lo - BB.lngMin) / dLng);
    let cy = Math.floor((la - BB.latMin) / dLat);
    if (cx < 0) cx = 0; if (cx >= GX) cx = GX - 1;
    if (cy < 0) cy = 0; if (cy >= GY) cy = GY - 1;
    cellOf[i] = cy * GX + cx;
  }
  for (let i = 0; i < edgeCount; i++) cellStart[cellOf[i] + 1]++;
  for (let i = 0; i < cellCount; i++) cellStart[i + 1] += cellStart[i];
  const cursor = Uint32Array.from(cellStart);
  const cellEdge = new Uint32Array(edgeCount);
  for (let i = 0; i < edgeCount; i++) cellEdge[cursor[cellOf[i]]++] = i;

  // ---- encode TNG2
  const namesBuf = [];
  for (const n of nameList) {
    const b = Buffer.from(n, 'utf8');
    const len = Buffer.alloc(2);
    len.writeUInt16LE(Math.min(b.length, 65535), 0);
    namesBuf.push(len, b.subarray(0, Math.min(b.length, 65535)));
  }
  const namesBytes = Buffer.concat(namesBuf);

  const headerBytes = 48;
  const nodeBytes = nodeCount * 8;
  const edgeBytes = edgeCount * 16;
  const gridBytes = (cellCount + 1) * 4 + edgeCount * 4;
  const total = headerBytes + nodeBytes + edgeBytes + namesBytes.length + gridBytes;

  const out = Buffer.allocUnsafe(total);
  out.write('TNG2', 0, 'ascii');
  out.writeUInt32LE(2, 4);
  out.writeUInt32LE(nodeCount, 8);
  out.writeUInt32LE(edgeCount, 12);
  out.writeUInt32LE(nameList.length, 16);
  out.writeUInt32LE(CLASSES.length, 20);
  out.writeUInt16LE(GX, 24);
  out.writeUInt16LE(GY, 26);
  out.writeInt32LE(Math.round(BB.latMin * 1e6), 28);
  out.writeInt32LE(Math.round(BB.lngMin * 1e6), 32);
  out.writeInt32LE(Math.round(BB.latMax * 1e6), 36);
  out.writeInt32LE(Math.round(BB.lngMax * 1e6), 40);
  out.writeUInt32LE(cellCount, 44);

  let o = headerBytes;
  for (let i = 0; i < nodeCount; i++) { out.writeInt32LE(latArr[i], o); o += 4; }
  for (let i = 0; i < nodeCount; i++) { out.writeInt32LE(lngArr[i], o); o += 4; }
  for (let i = 0; i < edgeCount; i++) {
    out.writeUInt32LE(ea[i], o);
    out.writeUInt32LE(eb[i], o + 4);
    out.writeUInt16LE(em[i], o + 8);
    out.writeUInt8(ec[i], o + 10);
    out.writeUInt8(ef[i], o + 11);
    out.writeUInt32LE(en[i] === NONE ? NONE : en[i], o + 12);
    o += 16;
  }
  namesBytes.copy(out, o); o += namesBytes.length;
  for (let i = 0; i <= cellCount; i++) { out.writeUInt32LE(cellStart[i], o); o += 4; }
  for (let i = 0; i < edgeCount; i++) { out.writeUInt32LE(cellEdge[i], o); o += 4; }
  if (o !== total) throw new Error(`size mismatch ${o} != ${total}`);

  const gz = zlib.gzipSync(out, { level: 9 });
  fs.writeFileSync(path.join(ASSETS, 'tn_roads.bin.gz'), gz);
  log(`wrote tn_roads.bin.gz  raw ${(total / 1048576).toFixed(1)} MB -> gzip ${(gz.length / 1048576).toFixed(1)} MB`);

  const byClass = {};
  for (let i = 0; i < edgeCount; i++) {
    const c = CLASSES[ec[i]] || 'other';
    byClass[c] = (byClass[c] || 0) + 1;
  }
  const meta = {
    version: 2,
    format: 'TNG2',
    source: 'OpenStreetMap via Overpass API',
    attribution: '\u00a9 OpenStreetMap contributors (ODbL)',
    generated: new Date().toISOString(),
    groups: groupArg,
    bbox: BB,
    nodes: nodeCount,
    edges: edgeCount,
    names: nameList.length,
    gridX: GX,
    gridY: GY,
    rawBytes: total,
    gzipBytes: gz.length,
    byClass,
  };
  fs.writeFileSync(path.join(ASSETS, 'tn_roads.meta.json'), JSON.stringify(meta, null, 2));
  log('meta written');
  return meta;
}

// ---------------------------------------------------------------- places

async function buildPlaces() {
  const cacheKey = 'places';
  const q = `[out:json][timeout:180];`
    + `node["place"~"^(city|town|municipality|village)$"](${BB.latMin},${BB.lngMin},${BB.latMax},${BB.lngMax});`
    + `out body;`;
  let j;
  try {
    j = await overpass(q, cacheKey);
  } catch (e) {
    log('places FAILED: ' + e.message);
    return;
  }
  const seen = new Set();
  const places = [];
  for (const el of j.elements) {
    if (el.type !== 'node') continue;
    const t = el.tags || {};
    const name = t.name || t['name:en'];
    if (!name) continue;
    const key = name + '|' + Math.round(el.lat * 100) + '|' + Math.round(el.lon * 100);
    if (seen.has(key)) continue;
    seen.add(key);
    const rank = t.place === 'city' ? 1 : t.place === 'municipality' ? 2 : t.place === 'town' ? 3 : 4;
    places.push({ n: name, la: +el.lat.toFixed(5), lo: +el.lon.toFixed(5), r: rank });
  }
  places.sort((a, b) => a.r - b.r);
  const raw = Buffer.from(JSON.stringify({ attribution: '\u00a9 OpenStreetMap contributors', places }));
  const gz = zlib.gzipSync(raw, { level: 9 });
  fs.writeFileSync(path.join(ASSETS, 'tn_places.json.gz'), gz);
  log(`wrote tn_places.json.gz ${places.length} places (${(gz.length / 1024).toFixed(1)} KB)`);
}

(async () => {
  const t0 = Date.now();
  try {
    if (groupArg === 'places') {
      await buildPlaces();
    } else {
      const meta = await buildGraph();
      log('DONE in ' + ((Date.now() - t0) / 1000).toFixed(0) + 's');
      log(JSON.stringify({ nodes: meta.nodes, edges: meta.edges, gz: (meta.gzipBytes / 1048576).toFixed(1) + ' MB' }));
    }
  } catch (e) {
    console.error('FAILED:', e.stack || e.message);
    process.exit(1);
  }
})();
