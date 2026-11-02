/* eslint-disable */
/**
 * Build the map's town/city label file from the bundled police-station data.
 *
 * Every police station carries a city and a district, and police stations are
 * located in the towns they serve - so the station list is an excellent (and
 * completely free) source of place labels for the offline map. No network
 * needed.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const ROOT = path.resolve(__dirname, '..', '..');
const ASSETS = path.join(ROOT, 'mobile', 'assets');

const gz = zlib.gunzipSync(
  fs.readFileSync(path.join(ASSETS, 'tn_stations.json.gz')),
);
const data = JSON.parse(gz.toString('utf8'));
const stations = data.stations || [];

const districts = new Set(
  stations.map((s) => (s.district || '').trim().toLowerCase()).filter(Boolean),
);

const byName = new Map();

function add(name, lat, lng) {
  if (!name) return;
  const key = name.trim().toLowerCase();
  const cur = byName.get(key);
  if (!cur) {
    byName.set(key, {
      n: name.trim(), la: +lat.toFixed(5), lo: +lng.toFixed(5),
      c: 1, sx: +lat.toFixed(5), sy: +lng.toFixed(5),
    });
  } else {
    cur.c++;
    cur.sx += lat;
    cur.sy += lng;
    cur.la = +(cur.sx / cur.c).toFixed(5);
    cur.lo = +(cur.sy / cur.c).toFixed(5);
  }
}

for (const s of stations) {
  if (s.lat == null || s.lng == null) continue;
  add(s.city, s.lat, s.lng);
  add(s.district, s.lat, s.lng);
}

const places = [];
for (const p of byName.values()) {
  // A place name shared by several stations is a real town; a name that
  // appears once is usually the station's own name, so it is not a label.
  if (p.c < 2) continue;
  const isDistrict = districts.has(p.n.toLowerCase());
  let rank;
  if (isDistrict) rank = p.c >= 8 ? 1 : 2;      // big districts read as cities
  else rank = p.c >= 6 ? 1 : 2;                // many stations => a real town
  places.push({ n: p.n, la: p.la, lo: p.lo, r: rank });
}
places.sort((a, b) => a.r - b.r || a.n.localeCompare(b.n));

const out = Buffer.from(JSON.stringify({
  attribution: '(c) OpenStreetMap contributors',
  source: 'derived from the bundled police-station directory',
  places,
}));
const gzOut = zlib.gzipSync(out, { level: 9 });
fs.writeFileSync(path.join(ASSETS, 'tn_places.json.gz'), gzOut);

const ranks = places.reduce((m, p) => (m[p.r] = (m[p.r] || 0) + 1, m), {});
console.log('places:', places.length, JSON.stringify(ranks),
  '-> ', (gzOut.length / 1024).toFixed(1), 'KB');
console.log('sample:', JSON.stringify(places.slice(0, 6)));
