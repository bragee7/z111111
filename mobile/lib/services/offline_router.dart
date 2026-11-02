import 'dart:math' as math;
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import '../models/police_station.dart';
import 'road_graph.dart';

/// Travel profiles the offline router understands.
enum TravelMode { car, bike, walk }

TravelMode travelModeFrom(String raw) {
  switch (raw.toLowerCase()) {
    case 'bike':
    case 'bicycle':
    case 'cycle':
      return TravelMode.bike;
    case 'walk':
    case 'walking':
    case 'foot':
    case 'pedestrian':
      return TravelMode.walk;
    default:
      return TravelMode.car;
  }
}

/// A road-graph node a point snapped to, plus how far the point is from it.
class SnapPoint {
  const SnapPoint(this.node, this.metres);
  final int node;
  final double metres;
}

/// A destination resolved to graph nodes (cached by the caller).
class RouterTarget {
  const RouterTarget({
    required this.node,
    required this.offRoadMetres,
    required this.payloadIndex,
  });

  final int node;
  final double offRoadMetres;

  /// Index of the original item (e.g. the station in a list).
  final int payloadIndex;
}

/// The winning target of a multi-destination search.
class NearestHit {
  const NearestHit({
    required this.payloadIndex,
    required this.route,
  });

  final int payloadIndex;
  final OfflineRoute route;
}

/// On-device A* router over the bundled OpenStreetMap road graph.
///
/// Works with **no network at all**. Costs are seconds, so the same search
/// produces a genuinely different answer for car, bicycle and walking: the
/// profile decides which road classes are usable, how fast each one is, and
/// whether one-way streets apply.
class OfflineRouter {
  OfflineRouter(this.graph);

  final RoadGraph graph;

  /// Walking to (or from) the road network is penalised.
  ///
  /// Without this the router happily cuts straight across the city instead of
  /// using the streets, because a straight line is always shorter than the
  /// detour to the nearest road. A 3x penalty means the road network wins
  /// unless the point is right beside a road.
  static const double kSnapPenalty = 3.0;

  /// Cost in seconds of walking `metres` off the road network.
  static double _snapCost(double metres) => metres * kSnapPenalty / 1.4;

  /// Reusable search buffers; a route over a big graph should not allocate.
  Float32List? _g;
  Int32List? _cameFrom;
  Int32List? _cameEdge;
  Uint8List? _closed;
  final List<int> _touched = <int>[];

  _Heap? _heap;

  // ---------------------------------------------------------------- profiles

  /// Metres per second for each road class, per mode. 0 = not allowed.
  static final Map<TravelMode, Float32List> _speed = {
    TravelMode.car: Float32List.fromList([
      27.8, // motorway
      22.2, // trunk
      16.7, // primary
      13.9, // secondary
      11.1, // tertiary
      8.3, // unclassified
      6.9, // residential
      3.3, // living_street
      4.2, // service
      22.2, // motorway_link
      16.7, // trunk_link
      13.9, // primary_link
      11.1, // secondary_link
      9.7, // tertiary_link
      8.3, // road
      4.0, // track
      1.4, // path
      1.4, // footway
      4.0, // cycleway
    ]),
    TravelMode.bike: Float32List.fromList([
      0, // motorway (banned)
      4.4, // trunk (legal but unpleasant)
      4.8, // primary
      5.0, // secondary
      5.0, // tertiary
      4.8, // unclassified
      4.6, // residential
      3.2, // living_street
      3.0, // service
      0, // motorway_link
      4.4, // trunk_link
      4.8, // primary_link
      5.0, // secondary_link
      5.0, // tertiary_link
      4.8, // road
      3.6, // track
      3.0, // path
      3.0, // footway
      5.0, // cycleway
    ]),
    TravelMode.walk: Float32List.fromList([
      0, // motorway (banned)
      1.1, // trunk (last resort only)
      1.35, // primary
      1.35, // secondary
      1.35, // tertiary
      1.3, // unclassified
      1.3, // residential
      1.3, // living_street
      1.2, // service
      0, // motorway_link
      1.1, // trunk_link
      1.35, // primary_link
      1.35, // secondary_link
      1.35, // tertiary_link
      1.3, // road
      1.2, // track
      1.3, // path
      1.3, // footway
      1.3, // cycleway
    ]),
  };

  // ---------------------------------------------------------------- snapping

  /// Snap a coordinate to the nearest few road nodes, cheapest first.
  ///
  /// More than one candidate is returned so a point beside a dual carriageway
  /// or in a dense junction still finds a valid start.
  List<SnapPoint> snap(LatLng p, {int k = 4}) {
    if (graph.isEmpty) return const [];
    final ids = graph.nearestNodes(p.latitude, p.longitude, k: k);
    return [
      for (final id in ids)
        SnapPoint(
          id,
          RoadGraph.haversine(
              p.latitude, p.longitude, graph.latAt(id), graph.lngAt(id)),
        ),
    ];
  }

  // ---------------------------------------------------------------- routing

  void _resetBuffers() {
    final n = graph.nodeCount;
    if (_g == null || _g!.length != n) {
      _g = Float32List(n)..fillRange(0, n, double.infinity);
      _cameFrom = Int32List(n)..fillRange(0, n, -1);
      _cameEdge = Int32List(n)..fillRange(0, n, -1);
      _closed = Uint8List(n);
      _heap = _Heap(n);
    } else {
      for (final i in _touched) {
        _g![i] = double.infinity;
        _cameFrom![i] = -1;
        _cameEdge![i] = -1;
        _closed![i] = 0;
      }
    }
    _touched.clear();
    _heap!.clear();
  }

  /// Speed used for the A* heuristic, in metres per second.
  ///
  /// A strictly admissible heuristic would divide by the fastest road in the
  /// network (27.8 m/s for a motorway). On a 500 km cross-state route that
  /// estimate is so loose that A* degenerates into Dijkstra and has to sweep
  /// the entire graph. These are the realistic average speeds instead: the
  /// search stays in a narrow corridor around the direct line and finishes in
  /// milliseconds. The result can be a percent or two longer than the
  /// theoretical optimum, which is irrelevant for reaching a police station.
  /// ("Nearest station" still uses an exact Dijkstra, so the *choice* of
  /// station is always optimal.)
  static double _heuristicSpeed(TravelMode m) => switch (m) {
        TravelMode.car => 16.7,
        TravelMode.bike => 4.4,
        TravelMode.walk => 1.3,
      };

  /// Shortest (fastest) road route between two coordinates.
  OfflineRoute? between({
    required LatLng from,
    required LatLng to,
    TravelMode mode = TravelMode.car,
  }) {
    if (graph.isEmpty) return null;
    final starts = snap(from, k: 5);
    final goals = snap(to, k: 5);
    if (starts.isEmpty || goals.isEmpty) return null;

    final goalCost = <int, double>{};
    for (final gnode in goals) {
      final c = _snapCost(gnode.metres);
      final prev = goalCost[gnode.node];
      if (prev == null || c < prev) goalCost[gnode.node] = c;
    }

    // heuristic: straight-line to the closest goal node
    final goalLat = <int, double>{};
    for (final gn in goals) {
      goalLat[gn.node] = 0;
    }

    final res = _search(
      starts: starts,
      isGoal: (n) => goalCost.containsKey(n),
      goalExtra: (n) => goalCost[n] ?? double.infinity,
      heuristic: (n) {
        var best = double.infinity;
        for (final gn in goals) {
          final d = RoadGraph.haversine(
              graph.latAt(n), graph.lngAt(n), graph.latAt(gn.node),
              graph.lngAt(gn.node));
          if (d < best) best = d;
        }
        return best / _heuristicSpeed(mode);
      },
      mode: mode,
      maxPops: 2500000,
    );
    if (res == null) return null;

    return _finish(
      goal: res.node,
      costSeconds: res.cost,
      from: from,
      to: to,
      mode: mode,
    );
  }

  /// The best route to whichever target is cheapest to reach.
  ///
  /// One Dijkstra pass over the whole target set - not one search per station -
  /// so asking "which police station is nearest by road" stays instant even
  /// with 1,300 candidates.
  NearestHit? nearest({
    required LatLng from,
    required List<RouterTarget> targets,
    TravelMode mode = TravelMode.car,
    int maxPops = 900000,
  }) {
    if (graph.isEmpty || targets.isEmpty) return null;
    final starts = snap(from, k: 5);
    if (starts.isEmpty) return null;

    final byNode = <int, List<RouterTarget>>{};
    for (final t in targets) {
      (byNode[t.node] ??= <RouterTarget>[]).add(t);
    }

    final res = _search(
      starts: starts,
      isGoal: (n) => byNode.containsKey(n),
      goalExtra: (n) {
        var best = double.infinity;
        for (final t in byNode[n] ?? const <RouterTarget>[]) {
          final c = _snapCost(t.offRoadMetres);
          if (c < best) best = c;
        }
        return best;
      },
      heuristic: (_) => 0.0, // Dijkstra: the target is whatever is closest
      mode: mode,
      maxPops: maxPops,
    );
    if (res == null) return null;

    // pick the winning payload at that node
    var bestIdx = -1;
    var bestCost = double.infinity;
    for (final t in byNode[res.node] ?? const <RouterTarget>[]) {
      final c = _snapCost(t.offRoadMetres);
      if (c < bestCost) {
        bestCost = c;
        bestIdx = t.payloadIndex;
      }
    }
    if (bestIdx < 0) return null;

    final route = _finish(
      goal: res.node,
      costSeconds: res.cost,
      from: from,
      to: null,
      mode: mode,
    );
    return NearestHit(payloadIndex: bestIdx, route: route);
  }

  _SearchResult? _search({
    required List<SnapPoint> starts,
    required bool Function(int) isGoal,
    required double Function(int) goalExtra,
    required double Function(int) heuristic,
    required TravelMode mode,
    int maxPops = 900000,
  }) {
    _resetBuffers();
    final g = _g!;
    final cameFrom = _cameFrom!;
    final cameEdge = _cameEdge!;
    final closed = _closed!;
    final heap = _heap!;
    final off = graph.adjOff;
    final adj = graph.adjEdge;
    final speed = _speed[mode]!;

    for (final s in starts) {
      final c = _snapCost(s.metres);
      if (c < g[s.node]) {
        g[s.node] = c;
        if (cameFrom[s.node] == -1) _touched.add(s.node);
        heap.add(c + heuristic(s.node), s.node);
      }
    }

    var pops = 0;
    int? found;
    double foundCost = double.infinity;

    while (heap.isNotEmpty) {
      final cur = heap.pop();
      if (closed[cur] == 1) continue;
      closed[cur] = 1;
      if (++pops > maxPops) break;

      // Any path through this node costs at least g[cur], so once that is not
      // better than the best route already found we can stop. This holds for
      // any heuristic, admissible or not.
      if (g[cur] >= foundCost) break;

      if (isGoal(cur)) {
        final total = g[cur] + goalExtra(cur);
        if (total < foundCost) {
          foundCost = total;
          found = cur;
        }
        // NOTE: goal nodes are still expanded. A route often reaches one
        // candidate goal and then continues to a better one, so stopping here
        // would hide the better answer.
      }

      final s = off[cur];
      final e = off[cur + 1];
      final gcur = g[cur];
      for (var k = s; k < e; k++) {
        final ei = adj[k];
        final int nb;
        final bool forward;
        if (graph.edgeA(ei) == cur) {
          nb = graph.edgeB(ei);
          forward = true;
        } else {
          nb = graph.edgeA(ei);
          forward = false;
        }
        if (closed[nb] == 1) continue;
        final sp = speed[graph.edgeClass(ei)];
        if (sp <= 0) continue;
        if (mode == TravelMode.car) {
          final f = graph.edgeFlags(ei);
          if (f == RoadGraph.flagOnewayFwd && !forward) continue;
          if (f == RoadGraph.flagOnewayRev && forward) continue;
        }
        final metres = graph.edgeMetresRaw(ei).toDouble();
        final cost = gcur + metres / sp;
        if (cost < g[nb]) {
          if (cameFrom[nb] == -1) _touched.add(nb);
          g[nb] = cost;
          cameFrom[nb] = cur;
          cameEdge[nb] = ei;
          heap.add(cost + heuristic(nb), nb);
        }
      }
    }

    if (found == null) return null;
    return _SearchResult(found, foundCost);
  }

  OfflineRoute _finish({
    required int goal,
    required double costSeconds,
    required LatLng from,
    LatLng? to,
    required TravelMode mode,
  }) {
    final cameFrom = _cameFrom!;
    final cameEdge = _cameEdge!;

    final nodes = <int>[];
    final edgeIds = <int>[];
    var node = goal;
    var guard = 0;
    while (node >= 0 && guard++ < 2000000) {
      nodes.add(node);
      final e = cameEdge[node];
      if (e >= 0) edgeIds.add(e);
      node = cameFrom[node];
    }
    final revNodes = nodes.reversed.toList();
    final revEdges = edgeIds.reversed.toList();

    // geometry: real origin -> road nodes -> real destination
    final geometry = <LatLng>[from];
    var metres = 0.0;
    for (var i = 0; i < revNodes.length; i++) {
      final lat = graph.latAt(revNodes[i]);
      final lng = graph.lngAt(revNodes[i]);
      if (i > 0) {
        metres += graph.edgeMetresRaw(revEdges[i - 1]).toDouble();
      }
      final last = geometry.last;
      if (last.latitude != lat || last.longitude != lng) {
        geometry.add(LatLng(lat, lng));
      }
    }
    if (to != null) {
      metres += RoadGraph.haversine(
          graph.latAt(goal), graph.lngAt(goal), to.latitude, to.longitude);
      geometry.add(to);
    }

    return OfflineRoute(
      metres: metres,
      seconds: costSeconds,
      geometry: _simplify(geometry),
      steps: _buildSteps(revNodes, revEdges, mode),
    );
  }

  /// Drop points that are within a pixel of the line (cheap Douglas-Peucker
  /// style) so the polyline handed to the canvas stays short.
  List<LatLng> _simplify(List<LatLng> pts, {double toleranceMetres = 6}) {
    if (pts.length <= 2) return pts;
    final out = <LatLng>[pts.first];
    var last = pts.first;
    for (var i = 1; i < pts.length - 1; i++) {
      final p = pts[i];
      final d = RoadGraph.haversine(
          last.latitude, last.longitude, p.latitude, p.longitude);
      if (d >= toleranceMetres) {
        out.add(p);
        last = p;
      }
    }
    out.add(pts.last);
    return out;
  }

  // ---------------------------------------------------------------- steps

  List<RouteStep> _buildSteps(
      List<int> nodes, List<int> edges, TravelMode mode) {
    final steps = <RouteStep>[];
    if (edges.isEmpty) return steps;

    var i = 0;
    var first = true;
    while (i < edges.length) {
      final name = graph.edgeName(edges[i]);
      final cls = graph.edgeClass(edges[i]);
      var j = i;
      var dist = 0.0;
      while (j < edges.length &&
          graph.edgeName(edges[j]) == name &&
          graph.edgeClass(edges[j]) == cls) {
        dist += graph.edgeMetresRaw(edges[j]).toDouble();
        j++;
      }
      final fromNode = i < nodes.length ? nodes[i] : nodes.last;
      final toNode = j < nodes.length ? nodes[j] : nodes.last;
      final bearing = _bearing(fromNode, toNode);
      final prevBearing = i > 0 && i - 1 < nodes.length
          ? _bearing(nodes[i - 1], nodes[i])
          : null;
      final turn = first
          ? 'start'
          : (prevBearing == null ? 'straight' : _turnType(prevBearing, bearing));
      final label = name.isEmpty ? _classLabel(cls) : name;
      final speed = _speed[mode]![cls];
      final secs = speed > 0 ? dist / speed : dist / 1.2;

      final verb = _modeVerb(mode);
      steps.add(RouteStep(
        type: turn,
        instruction: first
            ? '$verb ${_compass(bearing)} on $label.'
            : '${_turnWord(turn)} $label.',
        street: label,
        distance: dist,
        time: secs,
      ));
      first = false;
      i = j;
    }
    steps.add(RouteStep(
      type: 'arrive',
      instruction: mode == TravelMode.walk
          ? 'You have arrived on foot at the police station.'
          : 'You have arrived at the police station.',
      street: '',
      distance: 0,
      time: 0,
    ));
    return steps;
  }

  String _modeVerb(TravelMode m) => switch (m) {
        TravelMode.walk => 'Walk',
        TravelMode.bike => 'Cycle',
        TravelMode.car => 'Drive',
      };

  String _classLabel(int cls) => switch (cls) {
        RoadGraph.cMotorway => 'the motorway',
        RoadGraph.cTrunk => 'the highway',
        RoadGraph.cPrimary => 'the main road',
        RoadGraph.cSecondary => 'the secondary road',
        RoadGraph.cTertiary => 'the district road',
        _ => 'the road',
      };

  double _bearing(int a, int b) {
    final lat1 = graph.latAt(a) * math.pi / 180;
    final lat2 = graph.latAt(b) * math.pi / 180;
    final dLng = (graph.lngAt(b) - graph.lngAt(a)) * math.pi / 180;
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    return math.atan2(y, x) * 180 / math.pi;
  }

  String _turnType(double from, double to) {
    final d = (to - from + 540) % 360 - 180;
    final a = d.abs();
    if (a < 18) return 'straight';
    if (a > 150) return 'uturn';
    if (a < 55) return d > 0 ? 'right' : 'left';
    if (a < 128) return d > 0 ? 'right' : 'left';
    return 'straight';
  }

  String _turnWord(String t) => switch (t) {
        'left' => 'Turn left onto',
        'right' => 'Turn right onto',
        'uturn' => 'Make a U-turn onto',
        'merge' => 'Merge onto',
        'roundabout' => 'At the roundabout, take the exit onto',
        _ => 'Continue on',
      };

  String _compass(double bearing) {
    final b = (bearing + 360) % 360;
    if (b < 45 || b >= 315) return 'north';
    if (b < 135) return 'east';
    if (b < 225) return 'south';
    return 'west';
  }
}

class _SearchResult {
  const _SearchResult(this.node, this.cost);
  final int node;
  final double cost;
}

/// The result of an on-device route.
class OfflineRoute {
  const OfflineRoute({
    required this.metres,
    required this.seconds,
    required this.geometry,
    required this.steps,
  });

  final double metres;
  final double seconds;
  final List<LatLng> geometry;
  final List<RouteStep> steps;

  int get minutes => (seconds / 60).round().clamp(1, 9999);
  double get km => metres / 1000;
  String get distanceLabel => '${km.toStringAsFixed(km < 10 ? 2 : 1)} km';

  PoliceRoute toPoliceRoute({PoliceStation? destination}) => PoliceRoute(
        source: 'offline',
        distance: metres,
        duration: seconds,
        geometry: geometry,
        steps: steps,
        destination: destination,
      );
}

/// Binary min-heap keyed on fScore, reused between searches.
class _Heap {
  _Heap(int capacity)
      : _f = Float64List(math.max(1024, capacity)),
        _n = Int32List(math.max(1024, capacity));

  Float64List _f;
  Int32List _n;
  int _size = 0;

  bool get isNotEmpty => _size > 0;

  void clear() {
    _size = 0;
  }

  void add(double f, int node) {
    if (_size >= _f.length) {
      final nf = Float64List(_f.length * 2);
      final nn = Int32List(_n.length * 2);
      nf.setRange(0, _size, _f);
      nn.setRange(0, _size, _n);
      _f = nf;
      _n = nn;
    }
    var i = _size++;
    _f[i] = f;
    _n[i] = node;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_f[p] <= _f[i]) break;
      final tf = _f[p], tn = _n[p];
      _f[p] = _f[i];
      _n[p] = _n[i];
      _f[i] = tf;
      _n[i] = tn;
      i = p;
    }
  }

  int pop() {
    final top = _n[0];
    _size--;
    if (_size > 0) {
      _f[0] = _f[_size];
      _n[0] = _n[_size];
      var i = 0;
      while (true) {
        final l = 2 * i + 1, r = l + 1;
        var s = i;
        if (l < _size && _f[l] < _f[s]) s = l;
        if (r < _size && _f[r] < _f[s]) s = r;
        if (s == i) break;
        final tf = _f[s], tn = _n[s];
        _f[s] = _f[i];
        _n[s] = _n[i];
        _f[i] = tf;
        _n[i] = tn;
        i = s;
      }
    }
    return top;
  }
}
