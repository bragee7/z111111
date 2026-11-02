import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../models/police_station.dart';
import '../services/location_service.dart';
import '../services/police_station_service.dart';

enum PsTab { nearby, all, map, districts }

enum PsStatus { idle, loading, ready, error }

/// Holds the police-station directory, the map state, routing and follow-me.
///
/// Everything the map needs lives here so the widgets stay dumb.
class PoliceStationsProvider extends ChangeNotifier {
  final PoliceStationService _service = PoliceStationService.instance;

  // ------------------------------------------------------------ state
  PsTab _tab = PsTab.nearby;
  PsStatus _status = PsStatus.idle;
  String _error = '';
  bool _offlineMode = false;

  List<PoliceStation> _all = const [];
  List<PoliceStation> _nearby = const [];
  List<DistrictHelpline> _districts = const [];

  double? _userLat;
  double? _userLng;
  double? _userAccuracy;

  PoliceRoute? _route;
  PoliceStation? _routeDestination;
  List<RouteCandidate> _candidates = const [];
  bool _routing = false;

  bool _following = false;
  StreamSubscription<AppLocation>? _positionSub;
  Timer? _recalcTimer;
  bool _offRoute = false;
  double _lastRouteDistanceM = 0;

  String _query = '';
  String _districtFilter = '';
  bool _sortByDistance = true;
  String _mode = 'auto';

  final int _hydrated = 0;
  final int _hydrateTotal = 0;
  final bool _hydrating = false;
  Timer? _hydratePoll;

  // ---------------------------------------------------------- getters
  PsTab get tab => _tab;
  PsStatus get status => _status;
  String get error => _error;
  bool get offlineMode => _offlineMode;
  List<PoliceStation> get all => _all;
  List<PoliceStation> get nearby => _nearby;
  List<DistrictHelpline> get districts => _districts;
  PsSource get source => _service.source;
  bool get isOffline => _service.isOffline;
  bool get hasOfflineRouter => _service.canRoute;
  ({int nodes, int edges}) get graphStats => _service.graphStats;
  double? get userLat => _userLat;
  double? get userLng => _userLng;
  double? get userAccuracy => _userAccuracy;
  LatLng? get userPoint =>
      (_userLat == null || _userLng == null) ? null : LatLng(_userLat!, _userLng!);
  PoliceRoute? get route => _route;
  PoliceStation? get routeDestination => _routeDestination;
  List<RouteCandidate> get candidates => _candidates;
  bool get routing => _routing;
  bool get following => _following;
  bool get offRoute => _offRoute;
  String get query => _query;
  String get districtFilter => _districtFilter;
  String get mode => _mode;
  bool get sortByDistance => _sortByDistance;
  int get hydrated => _hydrated;
  int get hydrateTotal => _hydrateTotal;
  bool get hydrating => _hydrating;

  /// The directory filtered by the search box + district chips.
  List<PoliceStation> get filtered {
    final q = _query.trim().toLowerCase();
    var list = _all;
    if (_districtFilter.isNotEmpty) {
      list = list.where((s) => s.district == _districtFilter).toList();
    }
    if (q.isNotEmpty) {
      list = list
          .where((s) =>
              s.name.toLowerCase().contains(q) ||
              s.district.toLowerCase().contains(q) ||
              (s.city ?? '').toLowerCase().contains(q) ||
              s.id.contains(q))
          .toList();
    }
    if (_sortByDistance && _userLat != null) {
      list = list
          .map((s) => s.hasCoords
              ? s.copyWith(distanceM: _haversine(_userLat!, _userLng!, s.lat!, s.lng!))
              : s)
          .toList();
      list.sort((a, b) {
        final da = a.distanceM ?? double.infinity;
        final db = b.distanceM ?? double.infinity;
        return da.compareTo(db);
      });
    } else {
      list = List<PoliceStation>.from(list)
        ..sort((a, b) {
          final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          return c != 0 ? c : a.district.compareTo(b.district);
        });
    }
    return list;
  }

  /// Every distinct district in the directory, alphabetically.
  List<String> get districtNames {
    final set = <String>{for (final s in _all) s.district};
    final list = set.toList()..sort();
    return list;
  }

  // ------------------------------------------------------------ setters
  void setTab(PsTab t) {
    if (_tab == t) return;
    _tab = t;
    notifyListeners();
  }

  void setQuery(String q) {
    _query = q;
    notifyListeners();
  }

  void setDistrictFilter(String d) {
    _districtFilter = _districtFilter == d ? '' : d;
    notifyListeners();
  }

  void toggleSort() {
    _sortByDistance = !_sortByDistance;
    notifyListeners();
  }

  void setMode(String m) {
    if (_mode == m) return;
    _mode = m;
    notifyListeners();
    // If a route is already on screen, recalculate it with the new profile.
    final dest = _routeDestination;
    if (dest != null && !_routing) {
      routeTo(dest);
    }
  }

  // -------------------------------------------------------------- load
  Future<void> load({bool force = false}) async {
    if (_status == PsStatus.loading) return;
    if (_all.isNotEmpty && !force) {
      _locateAndLoadNearby();
      return;
    }
    _status = PsStatus.loading;
    _error = '';
    notifyListeners();
    try {
      final results = await Future.wait([
        _service.fetchDirectory(),
        _service.fetchDistricts(),
      ]);
      _all = results[0] as List<PoliceStation>;
      _districts = results[1] as List<DistrictHelpline>;
      _offlineMode = _service.isOffline;
      _status = PsStatus.ready;
      notifyListeners();
      // The road graph streams in behind the directory; refresh the UI when it
      // lands so the "routing ready" state appears on its own.
      unawaited(_service.graphReady.then((_) {
        if (_status == PsStatus.ready) notifyListeners();
      }));
      _locateAndLoadNearby();
    } catch (e) {
      _status = PsStatus.error;
      _error = 'Could not load the police station directory.\n$e';
      notifyListeners();
    }
  }

  // ---------------------------------------------------------- location
  Future<void> _locateAndLoadNearby() async {
    final loc = await LocationService.getCurrent(fresh: true);
    if (loc == null) {
      await _loadNearbyWithoutLocation();
      return;
    }
    setUserLocation(loc.latitude, loc.longitude);
    await _loadNearby();
  }

  Future<void> _loadNearbyWithoutLocation() async {
    try {
      final list = await _service.fetchNearby(11.5, 78.4); // centre of Tamil Nadu
      _nearby = _withDistances(list);
      notifyListeners();
    } catch (e) {
      _error = 'Could not load nearby stations: $e';
      notifyListeners();
    }
  }

  Future<void> _loadNearby() async {
    if (_userLat == null || _userLng == null) return;
    try {
      final list = await _service.fetchNearby(_userLat!, _userLng!);
      _nearby = _withDistances(list);
      notifyListeners();
    } catch (e) {
      _error = 'Could not load nearby stations: $e';
      notifyListeners();
    }
  }

  List<PoliceStation> _withDistances(List<PoliceStation> list) {
    if (_userLat == null || _userLng == null) return list;
    final out = list
        .map((s) => s.hasCoords
            ? s.copyWith(distanceM: _haversine(_userLat!, _userLng!, s.lat!, s.lng!))
            : s)
        .toList();
    out.sort((a, b) =>
        (a.distanceM ?? double.infinity).compareTo(b.distanceM ?? double.infinity));
    return out;
  }

  /// Overrides the user's location (e.g. "pick on map").
  void setUserLocation(double lat, double lng, {double? accuracy}) {
    _userLat = lat;
    _userLng = lng;
    _userAccuracy = accuracy;
    notifyListeners();
  }

  // ------------------------------------------------------------ routing
  /// Route to the station with the shortest ROAD distance.
  Future<void> routeToNearest() async {
    if (_userLat == null || _userLng == null) {
      _error = 'Location is required to find the nearest station.';
      notifyListeners();
      return;
    }
    _routing = true;
    _offRoute = false;
    notifyListeners();
    final sw = Stopwatch()..start();
    try {
      final res = await _service.fetchNearestRoute(
        lat: _userLat!,
        lng: _userLng!,
        mode: _mode,
      );
      if (kDebugMode) {
        debugPrint('[offline-route] nearest($_mode) '
            '${sw.elapsedMilliseconds}ms -> ${res.station.name} '
            '${res.route.distanceLabel}');
      }
      _route = res.route;
      _routeDestination = res.station;
      _candidates = res.candidates;
      _tab = PsTab.map;
      notifyListeners();
    } catch (e) {
      _error = _friendlyRoutingError(e);
    } finally {
      _routing = false;
      notifyListeners();
    }
  }

  /// Route to a specific station.
  Future<void> routeTo(PoliceStation station) async {
    if (_userLat == null || _userLng == null) {
      _error = 'Location is required to draw a route.';
      notifyListeners();
      return;
    }
    if (!station.hasCoords) {
      _error = 'This station has no coordinates yet â€” try again once details finish loading.';
      notifyListeners();
      return;
    }
    _routing = true;
    _offRoute = false;
    notifyListeners();
    try {
      final r = await _service.fetchRoute(
        fromLat: _userLat!,
        fromLng: _userLng!,
        toLat: station.lat!,
        toLng: station.lng!,
        mode: _mode,
      );
      _route = PoliceRoute(
        source: r.source,
        distance: r.distance,
        duration: r.duration,
        geometry: r.geometry,
        steps: r.steps,
        destination: station,
      );
      _routeDestination = station;
      _candidates = const [];
      _tab = PsTab.map;
    } catch (e) {
      _error = _friendlyRoutingError(e);
    } finally {
      _routing = false;
      notifyListeners();
    }
  }

  /// Turn a routing failure into something a person can act on.
  String _friendlyRoutingError(Object e) {
    final msg = e.toString();
    if (msg.contains('No road route')) {
      return 'No road route available offline yet. Connect to the internet, '
          'or try again once the bundled road map finishes loading.';
    }
    if (msg.contains('No route available')) {
      return 'Could not find a road route between these two points. '
          'Check your location and try again.';
    }
    if (msg.contains('Offline routing is unavailable')) {
      return 'Offline routing is not available on this build. '
          'Connect to the internet to get turn-by-turn directions.';
    }
    if (msg.contains('Bad state')) {
      return 'No road route found to any station from here. '
          'Move closer to a city centre and try again.';
    }
    return 'Routing failed: $msg';
  }

  void clearRoute() {
    _route = null;
    _routeDestination = null;
    _candidates = const [];
    _offRoute = false;
    _recalcTimer?.cancel();
    _recalcTimer = null;
    notifyListeners();
  }

  // --------------------------------------------------------- follow me
  void startFollowing() {
    if (_following) return;
    _following = true;
    _offRoute = false;
    notifyListeners();
    _positionSub = LocationService.watchPosition().listen(
      _onPosition,
      onError: (_) {
        _following = false;
        notifyListeners();
      },
      cancelOnError: false,
    );
  }

  void stopFollowing() {
    _following = false;
    _positionSub?.cancel();
    _positionSub = null;
    _recalcTimer?.cancel();
    _recalcTimer = null;
    notifyListeners();
  }

  void _onPosition(AppLocation loc) {
    _userLat = loc.latitude;
    _userLng = loc.longitude;
    notifyListeners();

    final r = _route;
    if (r == null || r.geometry.isEmpty) return;

    final drift = _distanceToRoute(LatLng(loc.latitude, loc.longitude), r.geometry);
    _lastRouteDistanceM = drift;

    final nowOff = drift > 120;
    if (nowOff != _offRoute) {
      _offRoute = nowOff;
      notifyListeners();
    }

    if (nowOff) {
      // Timer-driven recalculation: do not depend on the next GPS event.
      _recalcTimer ??= Timer(const Duration(seconds: 15), () {
        _recalcTimer = null;
        final dest = _routeDestination;
        if (dest != null && _offRoute) {
          routeTo(dest);
        }
      });
    } else if (_recalcTimer != null) {
      _recalcTimer!.cancel();
      _recalcTimer = null;
    }
  }

  /// Perpendicular distance from a point to the route polyline, in metres.
  double _distanceToRoute(LatLng p, List<LatLng> line) {
    if (line.length < 2) return double.infinity;
    const mPerDegLat = 110574.0;
    const mPerDegLon = 111320.0;
    final kx = math.cos(p.latitude * math.pi / 180) * mPerDegLon;
    final ky = mPerDegLat;
    var min = double.infinity;
    for (var i = 0; i < line.length - 1; i++) {
      final a = line[i];
      final b = line[i + 1];
      final ax = (a.longitude - p.longitude) * kx, ay = (a.latitude - p.latitude) * ky;
      final bx = (b.longitude - p.longitude) * kx, by = (b.latitude - p.latitude) * ky;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      var t = len2 == 0 ? 0.0 : ((-ax) * dx + (-ay) * dy) / len2;
      if (t < 0) t = 0;
      if (t > 1) t = 1;
      final px = ax + t * dx, py = ay + t * dy;
      final d = math.sqrt(px * px + py * py);
      if (d < min) min = d;
    }
    return min;
  }

  double get offRouteDistance => _lastRouteDistanceM;

  // -------------------------------------------------------------- utils
  static double _haversine(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    double toRad(double d) => d * math.pi / 180;
    final dLat = toRad(lat2 - lat1);
    final dLng = toRad(lng2 - lng1);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(toRad(lat1)) * math.cos(toRad(lat2)) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.sqrt(h));
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _recalcTimer?.cancel();
    _hydratePoll?.cancel();
    super.dispose();
  }
}
