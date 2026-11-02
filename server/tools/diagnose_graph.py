#!/usr/bin/env python3
"""Diagnose the bundled graph: coverage, connectivity and snapping."""
import gzip
import math
import struct
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(os.path.abspath(os.path.join(HERE, "..", "..")),
                      "mobile", "assets")

raw = gzip.decompress(open(os.path.join(ASSETS, "tn_roads.bin.gz"), "rb").read())
magic = raw[:4]
version, n, e, nnames, nclasses = struct.unpack_from("<IIIII", raw, 4)
grid_x, grid_y = struct.unpack_from("<HH", raw, 24)
lat_min, lng_min, lat_max, lng_max = struct.unpack_from("<iiii", raw, 28)
cell_count = struct.unpack_from("<I", raw, 44)[0]
print("magic", magic, "ver", version, "nodes", n, "edges", e,
      "names", nnames, "classes", nclasses)
print("grid", grid_x, grid_y, "bbox", lat_min/1e6, lng_min/1e6,
      lat_max/1e6, lng_max/1e6, "cells", cell_count)

edge_off = 48 + n * 8
lats = struct.unpack_from("<%di" % n, raw, 48)
lngs = struct.unpack_from("<%di" % n, raw, 48 + n * 4)

# min/max of actual node coords
print("node lat range", min(lats)/1e6, max(lats)/1e6)
print("node lng range", min(lngs)/1e6, max(lngs)/1e6)


def nearest(lat, lng, label):
    best = None
    bd = 1e18
    for i in range(n):
        d = (lats[i]/1e6-lat)**2 + ((lngs[i]/1e6-lng)*math.cos(math.radians(lat)))**2
        if d < bd:
            bd = d
            best = i
    if best is None:
        print(label, "-> no nodes")
        return
    dist = math.sqrt(bd) * 111320
    print("%-24s -> node %d at %.5f,%.5f  (%.0f m away)"
          % (label, best, lats[best]/1e6, lngs[best]/1e6, dist))


nearest(13.0827, 80.2707, "Chennai centre")
nearest(13.0050, 80.2600, "Chennai Egmore")
nearest(11.0168, 76.9558, "Coimbatore")
nearest(10.7905, 78.7047, "Trichy")
nearest(9.9252, 78.1198, "Madurai")
nearest(8.7642, 77.1344, "Nagercoil")
nearest(12.9166, 79.8333, "Kumbakonam")
nearest(11.9404, 79.4862, "Puducherry-ish")

# how many edges within 5 km of Chennai centre?
cnt = 0
for i in range(0, e, 1):
    a, b = struct.unpack_from("<II", raw, edge_off + i*16)
    la = (lats[a] + lats[b])/2e6
    lo = (lngs[a] + lngs[b])/2e6
    if abs(la-13.0827) < 0.045 and abs(lo-80.2707) < 0.045:
        cnt += 1
print("edges within ~5km of Chennai centre:", cnt)
