import 'dart:math' as math;
import 'dart:typed_data';

/// Zero-copy reader for the bundled `TNG2` road graph.
///
/// Layout (little-endian):
/// ```
///   0  'TNG2'  | 4 version | 8 nodeCount | 12 edgeCount | 16 nameCount
///  20  classCount | 24 gridX u16 | 26 gridY u16
///  28  latMinE6 i32 | 32 lngMinE6 i32 | 36 latMaxE6 i32 | 40 lngMaxE6 i32
///  44  cellCount
///  48  latE6  : i32[nodeCount]
///      lngE6  : i32[nodeCount]
///      edges  : 16 B each -> a u32 | b u32 | metres u16 | class u8 | flags u8 | nameIdx u32
///      names  : u16 len + utf8
///      grid   : (cellCount+1) u32 starts, then u32[edgeCount] edge ids
/// ```
///
/// Everything is a typed-array *view* over one `Uint8List`, so loading a
/// multi-megabyte graph costs one gunzip and no per-record parsing.
class RoadGraph {
  RoadGraph._(this.bytes, this._adjOffIn, this._adjEdgeIn);

  final Uint8List bytes;
  final Int32List? _adjOffIn;
  final Int32List? _adjEdgeIn;

  // header
  late final int nodeCount;
  late final int edgeCount;
  late final int nameCount;
  late final int classCount;
  late final int gridX;
  late final int gridY;
  late final double latMin, lngMin, latMax, lngMax;
  late final int cellCount;

  // section offsets
  late final int _edgeOff;
  late final int _gridOff;
  late final int _cellEdgeOff;

  // views
  late final Int32List _latE6;
  late final Int32List _lngE6;
  late final Int32List _edgeI32; // 4 per edge
  late final Uint16List _edgeU16; // 8 per edge
  late final Uint8List _edgeU8; // 16 per edge
  late final Uint32List _cellStart;
  late final Uint32List _cellEdge;

  late final List<String> _names;

  /// CSR adjacency, built on first use (cheap ring for routing only).
  Int32List? _adjOff;
  Int32List? _adjEdge;

  int _builtAdj = 0;

  bool get isEmpty => nodeCount == 0 || edgeCount == 0;

  // roads that carry traffic on a map are drawn; these names match the
  // builder's class table order.
  static const List<String> classNames = [
    'motorway', 'trunk', 'primary', 'secondary', 'tertiary',
    'unclassified', 'residential', 'living_street', 'service',
    'motorway_link', 'trunk_link', 'primary_link', 'secondary_link',
    'tertiary_link', 'road', 'track', 'path', 'footway', 'cycleway',
  ];

  static const int cMotorway = 0;
  static const int cTrunk = 1;
  static const int cPrimary = 2;
  static const int cSecondary = 3;
  static const int cTertiary = 4;
  static const int cUnclassified = 5;
  static const int cResidential = 6;
  static const int cLivingStreet = 7;
  static const int cService = 8;

  static const int flagOnewayFwd = 1;
  static const int flagOnewayRev = 2;

  static RoadGraph fromBytes(
    Uint8List raw, {
    Int32List? adjacencyOffsets,
    Int32List? adjacencyEdges,
  }) {
    if (raw.length < 48) throw const FormatException('road graph too small');
    final bd = ByteData.sublistView(raw);
    if (raw[0] != 0x54 || raw[1] != 0x4e || raw[2] != 0x47 || raw[3] != 0x32) {
      throw const FormatException('not a TNG2 road graph');
    }
    final version = bd.getUint32(4, Endian.little);
    if (version != 2) {
      throw FormatException('unsupported road graph version $version');
    }
    final g = RoadGraph._(raw, adjacencyOffsets, adjacencyEdges)
      ..nodeCount = bd.getUint32(8, Endian.little)
      ..edgeCount = bd.getUint32(12, Endian.little)
      ..nameCount = bd.getUint32(16, Endian.little)
      ..classCount = bd.getUint32(20, Endian.little)
      ..gridX = bd.getUint16(24, Endian.little)
      ..gridY = bd.getUint16(26, Endian.little)
      ..latMin = bd.getInt32(28, Endian.little) / 1e6
      ..lngMin = bd.getInt32(32, Endian.little) / 1e6
      ..latMax = bd.getInt32(36, Endian.little) / 1e6
      ..lngMax = bd.getInt32(40, Endian.little) / 1e6
      ..cellCount = bd.getUint32(44, Endian.little);

    final nodeOff = 48;
    final n = g.nodeCount;
    final e = g.edgeCount;
    g._latE6 = Int32List.view(g.bytes.buffer, g.bytes.offsetInBytes + nodeOff, n);
    g._lngE6 =
        Int32List.view(g.bytes.buffer, g.bytes.offsetInBytes + nodeOff + n * 4, n);
    g._edgeOff = nodeOff + n * 8;
    g._edgeI32 =
        Int32List.view(g.bytes.buffer, g.bytes.offsetInBytes + g._edgeOff, e * 4);
    g._edgeU16 =
        Uint16List.view(g.bytes.buffer, g.bytes.offsetInBytes + g._edgeOff, e * 8);
    g._edgeU8 =
        Uint8List.view(g.bytes.buffer, g.bytes.offsetInBytes + g._edgeOff, e * 16);

    // names: variable length, parse once
    var o = g._edgeOff + e * 16;
    final names = <String>[];
    for (var i = 0; i < g.nameCount; i++) {
      final len = bd.getUint16(o, Endian.little);
      o += 2;
      if (len == 0) {
        names.add('');
      } else {
        names.add(String.fromCharCodes(g.bytes, o, o + len));
      }
      o += len;
    }
    g._names = names;

    g._gridOff = o;
    g._cellEdgeOff = o + (g.cellCount + 1) * 4;
    g._cellStart = Uint32List.view(
        g.bytes.buffer, g.bytes.offsetInBytes + g._gridOff, g.cellCount + 1);
    g._cellEdge = Uint32List.view(
        g.bytes.buffer, g.bytes.offsetInBytes + g._cellEdgeOff, e);
    return g;
  }

  // ------------------------------------------------------------ accessors

  double latAt(int n) => _latE6[n] / 1e6;
  double lngAt(int n) => _lngE6[n] / 1e6;

  int edgeA(int e) => _edgeI32[e * 4];
  int edgeB(int e) => _edgeI32[e * 4 + 1];
  int edgeMetresRaw(int e) => _edgeU16[e * 8 + 4];
  int edgeClass(int e) => _edgeU8[e * 16 + 10];
  int edgeFlags(int e) => _edgeU8[e * 16 + 11];
  int edgeNameIdx(int e) => _edgeI32[e * 4 + 3];

  String edgeName(int e) {
    final i = edgeNameIdx(e);
    if (i < 0 || i >= _names.length) return '';
    return _names[i];
  }

  String className(int e) {
    final c = edgeClass(e);
    return (c >= 0 && c < classNames.length) ? classNames[c] : 'road';
  }

  // ------------------------------------------------------------ adjacency

  void ensureAdjacency() {
    if (_builtAdj == 1) return;
    // Use the index that was built in the background isolate when we have it.
    if (_adjOffIn != null && _adjEdgeIn != null) {
      _adjOff = _adjOffIn;
      _adjEdge = _adjEdgeIn;
      _builtAdj = 1;
      return;
    }
    final n = nodeCount;
    final e = edgeCount;
    final counts = Int32List(n + 1);
    for (var i = 0; i < e; i++) {
      counts[edgeA(i) + 1]++;
      counts[edgeB(i) + 1]++;
    }
    for (var i = 0; i < n; i++) {
      counts[i + 1] += counts[i];
    }
    final cursor = Int32List.fromList(counts);
    final adj = Int32List(e * 2);
    for (var i = 0; i < e; i++) {
      final a = edgeA(i), b = edgeB(i);
      adj[cursor[a]++] = i;
      adj[cursor[b]++] = i;
    }
    _adjOff = counts;
    _adjEdge = adj;
    _builtAdj = 1;
  }

  Int32List get adjOff {
    ensureAdjacency();
    return _adjOff!;
  }

  Int32List get adjEdge {
    ensureAdjacency();
    return _adjEdge!;
  }

  // ------------------------------------------------------------ geometry

  double edgeMetres(int e) => edgeMetresRaw(e).toDouble();

  double edgeLengthMetres(int e) {
    return haversine(latAt(edgeA(e)), lngAt(edgeA(e)), latAt(edgeB(e)),
        lngAt(edgeB(e)));
  }

  // ------------------------------------------------------------ spatial

  double get _dLng => (lngMax - lngMin) / gridX;
  double get _dLat => (latMax - latMin) / gridY;

  /// Edge ids whose midpoint falls inside the lat/lng box.
  ///
  /// Used by the offline map to draw only what is on screen.
  void edgesInBox(double s, double w, double n, double e, Int32ListSink out) {
    if (isEmpty) return;
    var cx0 = ((w - lngMin) / _dLng).floor();
    var cx1 = ((e - lngMin) / _dLng).floor();
    var cy0 = ((s - latMin) / _dLat).floor();
    var cy1 = ((n - latMin) / _dLat).floor();
    if (cx1 < 0 || cy1 < 0 || cx0 >= gridX || cy0 >= gridY) return;
    if (cx0 < 0) cx0 = 0;
    if (cy0 < 0) cy0 = 0;
    if (cx1 >= gridX) cx1 = gridX - 1;
    if (cy1 >= gridY) cy1 = gridY - 1;
    for (var cy = cy0; cy <= cy1; cy++) {
      final rowBase = cy * gridX;
      for (var cx = cx0; cx <= cx1; cx++) {
        final cell = rowBase + cx;
        final a = _cellStart[cell];
        final b = _cellStart[cell + 1];
        for (var k = a; k < b; k++) {
          out.add(_cellEdge[k]);
        }
      }
    }
  }

  /// Nearest graph nodes to a coordinate, best first.
  ///
  /// Searches outward from the containing grid cell, so this is O(edges in a
  /// few cells) instead of a full scan.
  List<int> nearestNodes(double lat, double lng, {int k = 6, int ring = 3}) {
    if (isEmpty) return const [];
    var cx = ((lng - lngMin) / _dLng).floor();
    var cy = ((lat - latMin) / _dLat).floor();
    if (cx < 0) cx = 0;
    if (cy < 0) cy = 0;
    if (cx >= gridX) cx = gridX - 1;
    if (cy >= gridY) cy = gridY - 1;

    final bestNode = <int>[];
    final bestDist = <double>[];
    double worstAccept() => bestDist.length < k ? double.infinity : bestDist.last;

    for (var r = 0; r <= ring; r++) {
      for (var yy = cy - r; yy <= cy + r; yy++) {
        if (yy < 0 || yy >= gridY) continue;
        for (var xx = cx - r; xx <= cx + r; xx++) {
          if (xx < 0 || xx >= gridX) continue;
          // only the ring perimeter on r > 0
          if (r > 0 && xx != cx - r && xx != cx + r && yy != cy - r && yy != cy + r) {
            continue;
          }
          final cell = yy * gridX + xx;
          final a = _cellStart[cell];
          final b = _cellStart[cell + 1];
          for (var i = a; i < b; i++) {
            final e = _cellEdge[i];
            final u = edgeA(e);
            final v = edgeB(e);
            _consider(u, lat, lng, bestNode, bestDist, k);
            _consider(v, lat, lng, bestNode, bestDist, k);
          }
        }
      }
      // once we have enough candidates and the next ring cannot beat them, stop
      if (bestDist.length >= k) {
        final ringMetres =
            math.max(_dLat, _dLng) * 111320.0 * (r + 1);
        if (worstAccept() < ringMetres) break;
      }
    }
    // merged sorted result
    final pairs = List.generate(bestNode.length, (i) => i)
      ..sort((a, b) => bestDist[a].compareTo(bestDist[b]));
    return [for (final i in pairs) bestNode[i]];
  }

  void _consider(int node, double lat, double lng, List<int> nodes,
      List<double> dists, int k) {
    final d = _sqMetres(lat, lng, latAt(node), lngAt(node));
    if (dists.length == k && d >= dists.last) return;
    if (nodes.contains(node)) return;
    var at = dists.length;
    for (var i = 0; i < dists.length; i++) {
      if (d < dists[i]) {
        at = i;
        break;
      }
    }
    nodes.insert(at, node);
    dists.insert(at, d);
    if (nodes.length > k) {
      nodes.removeLast();
      dists.removeLast();
    }
  }

  static double _sqMetres(double lat1, double lng1, double lat2, double lng2) {
    final dy = (lat1 - lat2) * 111320.0;
    final dx = (lng1 - lng2) * 111320.0 * math.cos(lat1 * math.pi / 180);
    return dx * dx + dy * dy;
  }

  static double haversine(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(lat2 - lat1);
    final dLng = rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(lat1)) *
            math.cos(rad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
  }
}

/// Tiny growable sink so the map can collect edge ids without allocating a
/// list of boxed ints per frame.
class Int32ListSink {
  Int32List _data = Int32List(1 << 14);
  int _length = 0;

  int get length => _length;
  Int32List get data => _data;

  void clear() {
    _length = 0;
  }

  void add(int v) {
    if (_length == _data.length) {
      final bigger = Int32List(_data.length * 2);
      bigger.setRange(0, _length, _data);
      _data = bigger;
    }
    _data[_length++] = v;
  }
}
