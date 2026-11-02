#!/usr/bin/env python3
"""
Build the bundled, fully-offline Tamil Nadu road graph from the official
OpenStreetMap state extract.

    https://download.openstreetmap.fr/extracts/asia/india/tamil_nadu.osm.pbf

Output (mobile/assets):
    tn_roads.bin.gz      TNG2 binary graph (nodes, edges, names, spatial grid)
    tn_roads.meta.json   human-readable summary

The same graph drives BOTH the offline map renderer and the on-device A*
router, so the map and the directions can never disagree.
"""

import gzip
import json
import math
import os
import struct
import sys
import time
import zlib
from collections import defaultdict

import osmium

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ASSETS = os.path.join(ROOT, "mobile", "assets")
PBF = os.path.join(HERE, "tamil_nadu.osm.pbf")

# road classes, in rendering / routing priority order (index == class id)
CLASSES = [
    "motorway", "trunk", "primary", "secondary", "tertiary",
    "unclassified", "residential", "living_street", "service",
    "motorway_link", "trunk_link", "primary_link", "secondary_link",
    "tertiary_link", "road",
]
CLASS_ID = {c: i for i, c in enumerate(CLASSES)}

# The arterial network: every road that matters for reaching a town, plus the
# district roads that carry traffic inside it. Residential and unclassified
# lanes are deliberately excluded - in Tamil Nadu they triple the size of the
# bundle (2.2 M ways -> 970 k) for very little routing gain, and the app has
# to load the whole graph into a phone's memory.
WANTED = {
    "motorway", "trunk", "primary", "secondary", "tertiary",
    "motorway_link", "trunk_link", "primary_link", "secondary_link",
    "tertiary_link", "road",
}

# bounding box of the extract (Tamil Nadu)
BB = dict(lat_min=7.95, lat_max=13.62, lng_min=76.10, lng_max=80.65)
GRID_X, GRID_Y = 128, 128
CELL_COUNT = GRID_X * GRID_Y

R = 6371000.0


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


class Handler(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.node_index = {}          # coord key -> dense node id
        self.lat = []                 # dense node id -> lat e6
        self.lng = []
        self.edges = []               # (a, b, metres, class, oneway, name)
        self.name_index = {}
        self.names = []
        self.ways_seen = 0
        self.ways_kept = 0
        self.nodes_seen = 0
        self.nodes_kept = 0
        self.dupes = 0

    # ------------------------------------------------------------------
    def node(self, n):
        self.nodes_seen += 1

    # ------------------------------------------------------------------
    def way(self, w):
        self.ways_seen += 1
        tags = w.tags
        hw = tags.get("highway")
        if hw not in WANTED:
            return
        try:
            nodes = w.nodes
        except Exception:
            return
        if len(nodes) < 2:
            return

        self.ways_kept += 1

        # one-way flags
        oneway = 0
        ow = (tags.get("oneway") or "").lower()
        junction = tags.get("junction")
        if ow in ("yes", "true", "1") or junction in ("roundabout", "circular"):
            oneway = 1
        elif ow in ("-1", "reverse"):
            oneway = 2

        name = tags.get("name") or tags.get("name:en") or tags.get("ref") or ""
        if name:
            ni = self.name_index.get(name)
            if ni is None:
                ni = len(self.names)
                self.name_index[name] = ni
                self.names.append(name)
        else:
            ni = 0xFFFFFFFF

        cls = CLASS_ID[hw]

        ids = []
        try:
            for ref in nodes:
                lon = ref.lon
                lat = ref.lat
                key = (int(round(lat * 1e6)) << 32) | (
                    int(round(lon * 1e6)) & 0xFFFFFFFF)
                idx = self.node_index.get(key)
                if idx is None:
                    idx = len(self.lat)
                    self.node_index[key] = idx
                    self.lat.append(int(round(lat * 1e6)))
                    self.lng.append(int(round(lon * 1e6)))
                    self.nodes_kept += 1
                else:
                    self.dupes += 1
                ids.append(idx)
        except osmium.InvalidLocationError:
            # A node outside the extract has no location: drop the whole way.
            return
        if len(ids) < 2:
            return

        la = self.lat
        lg = self.lng
        for i in range(len(ids) - 1):
            a, b = ids[i], ids[i + 1]
            if a == b:
                continue
            d = _haversine(la[a] / 1e6, lg[a] / 1e6, la[b] / 1e6, lg[b] / 1e6)
            if d < 0.5:
                continue
            if d > 65535:
                d = 65535.0
            self.edges.append((a, b, int(round(d)), cls, oneway, ni))

        if self.ways_kept % 20000 == 0:
            log("   ways kept %d  nodes %d  edges %d"
                % (self.ways_kept, self.nodes_kept, len(self.edges)))


def _haversine(lat1, lon1, lat2, lon2):
    p1 = math.radians(lat1)
    p2 = math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(min(1.0, math.sqrt(a)))


def main():
    if not os.path.exists(PBF):
        log("PBF missing:", PBF)
        sys.exit(2)

    log("parsing", PBF)
    h = Handler()
    h.apply_file(PBF, locations=True)
    log("done: %d ways seen, %d kept, %d nodes, %d edges, %d names"
        % (h.ways_seen, h.ways_kept, h.nodes_kept, len(h.edges), len(h.names)))

    n = h.nodes_kept
    e = len(h.edges)
    lat = h.lat
    lng = h.lng
    edges = h.edges
    names = h.names

    # ---------------- spatial grid (edge -> cell, by midpoint) -------------
    d_lng = (BB["lng_max"] - BB["lng_min"]) / GRID_X
    d_lat = (BB["lat_max"] - BB["lat_min"]) / GRID_Y
    cell_of = [0] * e
    counts = [0] * CELL_COUNT
    for i in range(e):
        a, b = edges[i][0], edges[i][1]
        la = (lat[a] + lat[b]) / 2e6
        lo = (lng[a] + lng[b]) / 2e6
        cx = int((lo - BB["lng_min"]) / d_lng)
        cy = int((la - BB["lat_min"]) / d_lat)
        if cx < 0:
            cx = 0
        if cx >= GRID_X:
            cx = GRID_X - 1
        if cy < 0:
            cy = 0
        if cy >= GRID_Y:
            cy = GRID_Y - 1
        c = cy * GRID_X + cx
        cell_of[i] = c
        counts[c] += 1

    cell_start = [0] * (CELL_COUNT + 1)
    run = 0
    for i in range(CELL_COUNT):
        cell_start[i] = run
        run += counts[i]
    cell_start[CELL_COUNT] = run
    cursor = cell_start[:]
    cell_edge = [0] * e
    for i in range(e):
        c = cell_of[i]
        cell_edge[cursor[c]] = i
        cursor[c] += 1

    # ---------------- encode TNG2 ----------------------------------------
    name_blobs = []
    for s in names:
        b = s.encode("utf-8")[:65535]
        name_blobs.append(struct.pack("<H", len(b)) + b)

    header = 48
    node_bytes = n * 8
    edge_bytes = e * 16
    names_bytes = sum(len(b) for b in name_blobs)
    grid_bytes = (CELL_COUNT + 1) * 4 + e * 4
    total = header + node_bytes + edge_bytes + names_bytes + grid_bytes

    out = bytearray(total)
    # header: magic | version | nodes | edges | names | classes | gridX | gridY
    #         | latMin | lngMin | latMax | lngMax | cellCount
    struct.pack_into("<4sIIIII", out, 0, b"TNG2", 2, n, e, len(names),
                     len(CLASSES))
    struct.pack_into("<HH", out, 24, GRID_X, GRID_Y)
    struct.pack_into("<iiii", out, 28,
                     int(BB["lat_min"] * 1e6), int(BB["lng_min"] * 1e6),
                     int(BB["lat_max"] * 1e6), int(BB["lng_max"] * 1e6))
    struct.pack_into("<I", out, 44, CELL_COUNT)

    o = header
    for v in lat:
        struct.pack_into("<i", out, o, v)
        o += 4
    for v in lng:
        struct.pack_into("<i", out, o, v)
        o += 4
    for i in range(e):
        a, b, m, cls, oneway, ni = edges[i]
        struct.pack_into("<IIHBB I", out, o, a, b, m, cls, oneway, ni)
        o += 16
    for b in name_blobs:
        out[o:o + len(b)] = b
        o += len(b)
    for v in cell_start:
        struct.pack_into("<I", out, o, v)
        o += 4
    for v in cell_edge:
        struct.pack_into("<I", out, o, v)
        o += 4
    assert o == total, (o, total)

    gz = gzip.compress(bytes(out), 9)
    with open(os.path.join(ASSETS, "tn_roads.bin.gz"), "wb") as f:
        f.write(gz)
    log("wrote tn_roads.bin.gz  raw %.1f MB -> gzip %.1f MB"
        % (total / 1048576, len(gz) / 1048576))

    by_class = defaultdict(int)
    for i in range(e):
        by_class[CLASSES[edges[i][3]]] += 1

    meta = {
        "version": 2,
        "format": "TNG2",
        "source": "OpenStreetMap state extract (tamil_nadu.osm.pbf)",
        "attribution": "\u00a9 OpenStreetMap contributors (ODbL)",
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "bbox": BB,
        "nodes": n,
        "edges": e,
        "names": len(names),
        "gridX": GRID_X,
        "gridY": GRID_Y,
        "rawBytes": total,
        "gzipBytes": len(gz),
        "byClass": dict(sorted(by_class.items())),
    }
    with open(os.path.join(ASSETS, "tn_roads.meta.json"), "w") as f:
        json.dump(meta, f, indent=2)
    log("meta written")
    log(json.dumps({"nodes": n, "edges": e,
                    "gzipMB": round(len(gz) / 1048576, 1)}))


if __name__ == "__main__":
    main()
