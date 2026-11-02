#!/usr/bin/env python3
"""Connectivity + search-cost analysis of the bundled graph."""
import gzip
import math
import os
import struct
import time
from array import array
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(os.path.abspath(os.path.join(HERE, "..", "..")),
                      "mobile", "assets")

raw = gzip.decompress(open(os.path.join(ASSETS, "tn_roads.bin.gz"), "rb").read())
version, n, e, nnames, nclasses = struct.unpack_from("<IIIII", raw, 4)
edge_off = 48 + n * 8
lats = array("i")
lats.frombytes(raw[48:48 + n * 4])
lngs = array("i")
lngs.frombytes(raw[48 + n * 4:48 + n * 8])

# CSR adjacency
t0 = time.time()
counts = array("i", bytes(4 * (n + 1)))
ea = array("i", bytes(4 * e))
eb = array("i", bytes(4 * e))
for i in range(e):
    a, b = struct.unpack_from("<II", raw, edge_off + i * 16)
    ea[i] = a
    eb[i] = b
    counts[a + 1] += 1
    counts[b + 1] += 1
for i in range(n):
    counts[i + 1] += counts[i]
off = array("i", counts)
adj = array("i", bytes(4 * 2 * e))
cur = array("i", counts)
for i in range(e):
    a, b = ea[i], eb[i]
    adj[cur[a]] = i
    cur[a] += 1
    adj[cur[b]] = i
    cur[b] += 1
print("adjacency built in %.1fs" % (time.time() - t0))


def nearest(lat, lng):
    best, bd = -1, 1e18
    for i in range(n):
        d = (lats[i]/1e6-lat)**2 + ((lngs[i]/1e6-lng)*math.cos(math.radians(lat)))**2
        if d < bd:
            bd, best = d, i
    return best


def bfs(start):
    seen = bytearray(n)
    seen[start] = 1
    q = deque([start])
    cnt = 1
    while q:
        v = q.popleft()
        for k in range(off[v], off[v+1]):
            i = adj[k]
            w = ea[i] if eb[i] == v else eb[i]
            if not seen[w]:
                seen[w] = 1
                cnt += 1
                q.append(w)
    return seen, cnt


chennai = nearest(13.0827, 80.2707)
coimbatore = nearest(11.0168, 76.9558)
trichy = nearest(10.7905, 78.7047)
print("nearest nodes: chennai %d coimbatore %d trichy %d"
      % (chennai, coimbatore, trichy))

t0 = time.time()
seen, cnt = bfs(chennai)
print("BFS from Chennai: reached %d of %d nodes (%.1f%%) in %.1fs"
      % (cnt, n, 100.0*cnt/n, time.time()-t0))
print("  coimbatore reachable:", bool(seen[coimbatore]))
print("  trichy reachable    :", bool(seen[trichy]))
if not seen[coimbatore]:
    # how far does the component reach?
    s2, c2 = bfs(coimbatore)
    print("  BFS from Coimbatore reaches %d nodes" % c2)
