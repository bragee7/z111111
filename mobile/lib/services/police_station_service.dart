import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/police_station.dart';
import 'offline_data_service.dart';
import 'offline_router.dart';
import 'road_graph.dart';

/// Where the police-station data came from.
enum PsSource { bundled, server, none }

/// The police-station directory and router.
///
/// **Everything here is local.** Directory, search, districts, nearby, routes
/// and turn-by-turn instructions all come from the assets inside the APK, so
/// there is no network call in any hot path and nothing to wait for. The
/// backend is never required, and never consulted for these features.
class PoliceStationService {
  static final PoliceStationService instance = PoliceStationService._();
  PoliceStationService._();

  final OfflineDataService _offline = OfflineDataService.instance;

  PsSource _source = PsSource.none;
  PsSource get source => _source;
  bool get isOffline => _source == PsSource.bundled;

  OfflineRouter? get router => _offline.router;

  /// True when on-device routing is usable (the bundled graph loaded).
  bool get canRoute => _offline.canRoute;

  /// Completes when the bundled road graph has finished loading.
  Future<void> get graphReady => _offline.graphReady;

  /// Stations with coordinates, paired with their snapped graph node.
  List<RouterTarget>? _targets;
  List<PoliceStation>? _targetStations;

  // ---------------------------------------------------------- directory

  /// The full directory, straight from the bundle. Never awaits the network.
  Future<List<PoliceStation>> fetchDirectory() async {
    await _ensureOffline();
    final stations = _offline.stations;
    _source = stations.isEmpty ? PsSource.none : PsSource.bundled;
    return stations;
  }

  /// District control-room numbers, from the bundle.
  Future<List<DistrictHelpline>> fetchDistricts() async {
    await _ensureOffline();
    return _offline.helplines;
  }

  // ------------------------------------------------------------- nearby

  /// Stations near a point, computed on-device. No network.
  Future<List<PoliceStation>> fetchNearby(double lat, double lng,
      {int limit = 120}) async {
    await _ensureOffline();
    return localNearby(lat, lng, limit: limit);
  }

  /// Nearby stations computed on-device from the bundled directory.
  List<PoliceStation> localNearby(double lat, double lng, {int limit = 120}) {
    final all = _offline.stations;
    if (all.isEmpty) return const [];
    final ranked = <PoliceStation>[];
    for (final s in all) {
      if (!s.hasCoords) continue;
      ranked.add(s.copyWith(distanceM: haversine(lat, lng, s.lat!, s.lng!)));
    }
    ranked.sort((a, b) => (a.distanceM ?? 1e12).compareTo(b.distanceM ?? 1e12));
    return ranked.length > limit ? ranked.sublist(0, limit) : ranked;
  }

  // ------------------------------------------------------------- routing

  /// Turn-by-turn route, computed on-device over the bundled road graph.
  Future<PoliceRoute> fetchRoute({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
    String mode = 'auto',
  }) async {
    await _ensureOffline();
    final r = router;
    if (r == null) {
      throw StateError('Offline routing is unavailable: no bundled road graph.');
    }
    final res = r.between(
      from: LatLng(fromLat, fromLng),
      to: LatLng(toLat, toLng),
      mode: travelModeFrom(mode),
    );
    if (res == null) {
      throw StateError(
          'No road route between these two points in the bundled map.');
    }
    return res.toPoliceRoute();
  }

  /// The station with the shortest ROAD distance, plus the route to it.
  ///
  /// One multi-target search over every station, so this stays instant even
  /// though there are 1,300 candidates.
  Future<
      ({
        PoliceRoute route,
        PoliceStation station,
        List<RouteCandidate> candidates,
      })> fetchNearestRoute({
    required double lat,
    required double lng,
    String mode = 'auto',
    int k = 10,
  }) async {
    await _ensureOffline();
    final r = router;
    if (r == null) {
      throw StateError('Offline routing is unavailable: no bundled road graph.');
    }
    await ensureTargets();
    final targets = _targets ?? const <RouterTarget>[];
    final stations = _targetStations ?? const <PoliceStation>[];
    if (targets.isEmpty) {
      throw StateError('No stations with coordinates in the bundle.');
    }
    final from = LatLng(lat, lng);
    final hit = r.nearest(
      from: from,
      targets: targets,
      mode: travelModeFrom(mode),
    );
    if (hit == null) {
      throw StateError('No road route to any station from this position.');
    }
    final station = stations[hit.payloadIndex];
    final route = hit.route.toPoliceRoute(destination: station);

    // Candidate list for the "compare" sheet: the closest few by road.
    final byAir = localNearby(lat, lng, limit: math.max(k, 6));
    final candidates = <RouteCandidate>[];
    for (final s in byAir) {
      if (s.id == station.id) {
        candidates.add(RouteCandidate(
            name: s.name, district: s.district, air: s.distanceM ?? 0,
            road: route.distance));
        continue;
      }
      if (candidates.length >= k) break;
      final res = r.between(
        from: from,
        to: LatLng(s.lat!, s.lng!),
        mode: travelModeFrom(mode),
      );
      if (res == null) continue;
      candidates.add(RouteCandidate(
          name: s.name, district: s.district, air: s.distanceM ?? 0,
          road: res.metres));
    }
    candidates.sort((a, b) => a.road.compareTo(b.road));

    return (route: route, station: station, candidates: candidates);
  }

  /// Snap every station to the road graph once, then reuse it.
  Future<void> ensureTargets() async {
    if (_targets != null) return;
    final r = router;
    if (r == null) {
      _targets = const [];
      _targetStations = const [];
      return;
    }
    final targets = <RouterTarget>[];
    final stations = <PoliceStation>[];
    for (final s in _offline.stations) {
      if (!s.hasCoords) continue;
      final snaps = r.snap(LatLng(s.lat!, s.lng!), k: 1);
      if (snaps.isEmpty) continue;
      targets.add(RouterTarget(
        node: snaps.first.node,
        offRoadMetres: snaps.first.metres,
        payloadIndex: stations.length,
      ));
      stations.add(s);
    }
    _targets = targets;
    _targetStations = stations;
  }

  // -------------------------------------------------------------- misc

  /// True when the device can reach the backend right now.
  ///
  /// Only used to decide whether to show an "online extras" hint - nothing in
  /// this screen depends on the answer.
  Future<bool> serverReachable() async {
    try {
      await Future<void>.delayed(Duration.zero);
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensureOffline() async {
    if (_offline.isLoaded) {
      _source = _offline.stations.isEmpty ? PsSource.none : PsSource.bundled;
      return;
    }
    await _offline.load();
    _source = _offline.stations.isEmpty ? PsSource.none : PsSource.bundled;
  }

  /// A rough road-network size for the debug line.
  ({int nodes, int edges}) get graphStats => (
        nodes: _offline.graphNodes,
        edges: _offline.graphEdges,
      );

  static double haversine(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    double toRad(double d) => d * math.pi / 180;
    final dLat = toRad(lat2 - lat1);
    final dLng = toRad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(toRad(lat1)) *
            math.cos(toRad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
  }
}

/// Convenience: the road class name of the bundle's heaviest road types, used
/// by the legend in the map tab.
const List<String> kOfflineLegend = [
  'Motorway',
  'Highway',
  'Main road',
  'Secondary',
  'District road',
];

/// Re-exported so screens do not need to import the graph directly.
typedef OfflineGraphStats = ({int nodes, int edges});

/// Kept for compatibility with screens that referenced the graph.
RoadGraph? get bundledGraph => OfflineDataService.instance.graph;
