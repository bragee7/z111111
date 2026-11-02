import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/place_label.dart';
import '../models/police_station.dart';
import 'offline_router.dart';
import 'road_graph.dart';

/// The bundled Tamil Nadu data set — no server, no network, no tile fetches.
///
///   assets/tn_stations.json.gz   1,317 police stations (address, phone, coords)
///   assets/tn_helplines.json.gz  district control-room numbers
///   assets/tn_roads.bin.gz       OSM road graph: map tiles AND routing
///   assets/tn_places.json.gz     city / town labels for the offline map
///
/// Everything is inflated once into typed arrays and then served from RAM, so
/// browsing, searching, drawing the map and routing never touch the network.
class OfflineDataService {
  static final OfflineDataService instance = OfflineDataService._();
  OfflineDataService._();

  List<PoliceStation>? _stations;
  List<DistrictHelpline>? _helplines;
  List<PlaceLabel>? _places;
  RoadGraph? _graph;
  OfflineRouter? _router;
  bool _loaded = false;
  Future<void>? _inFlight;
  Future<void>? _graphFuture;

  /// Completes when the road graph has been inflated and parsed.
  Future<void> get graphReady => _graphFuture ?? Future<void>.value();

  /// Diagnostics for the (hidden) offline status line.
  int graphRawBytes = 0;
  int graphNodes = 0;
  int graphEdges = 0;
  String? graphError;
  Duration loadTime = Duration.zero;

  bool get isLoaded => _loaded;
  List<PoliceStation> get stations => _stations ?? const [];
  List<DistrictHelpline> get helplines => _helplines ?? const [];
  List<PlaceLabel> get places => _places ?? const [];
  RoadGraph? get graph => _graph;
  OfflineRouter? get router => _router;

  /// True when the on-device road graph can actually compute routes.
  /// Browsing, search, filtering and the station list never need this.
  bool get canRoute => _router != null && _graph != null && !_graph!.isEmpty;

  Future<void> load({bool withGraph = true}) {
    if (_loaded) return Future.value();
    return _inFlight ??= _load(withGraph);
  }

  Future<void> _load(bool withGraph) async {
    final sw = Stopwatch()..start();
    _stations = await _readStations();
    _helplines = await _readHelplines();
    _places = await _readPlaces();
    sw.stop();
    loadTime = sw.elapsed;
    _loaded = true;
    if (kDebugMode) {
      debugPrint('[offline] stations=${_stations!.length} '
          'places=${_places!.length} in ${loadTime.inMilliseconds}ms');
    }
    // The road graph is big; inflate it after the directory is already on
    // screen so the UI never waits for it.
    if (withGraph) {
      _graphFuture = _readGraph();
      unawaited(_graphFuture!.then((_) {
        if (kDebugMode) {
          debugPrint('[offline] road graph: $graphNodes nodes, $graphEdges edges, '
              '${(graphRawBytes / 1048576).toStringAsFixed(1)}MB raw');
        }
      }).catchError((Object e) {
        graphError = e.toString();
        _graph = null;
        _router = null;
      }));
    }
  }

  Future<List<PoliceStation>> _readStations() async {
    final bytes = await _asset('tn_stations.json.gz');
    final raw = utf8.decode(gzip.decode(bytes));
    final j = json.decode(raw) as Map<String, dynamic>;
    final list = (j['stations'] as List?) ?? const [];
    return list.map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      return PoliceStation(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? 'Police Station').toString(),
        district: (m['district'] ?? 'Unknown').toString(),
        city: m['city'] as String?,
        address: m['address'] as String?,
        phone: (m['phone'] ?? '') as String?,
        lat: (m['lat'] as num?)?.toDouble(),
        lng: (m['lng'] as num?)?.toDouble(),
      );
    }).toList();
  }

  Future<List<DistrictHelpline>> _readHelplines() async {
    final bytes = await _asset('tn_helplines.json.gz');
    final raw = utf8.decode(gzip.decode(bytes));
    final j = json.decode(raw) as Map<String, dynamic>;
    final list = (j['districts'] as List?) ?? const [];
    return list.map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      return DistrictHelpline(
        district: (m['d'] ?? '').toString(),
        landline1: (m['l1'] ?? '') as String?,
        landline2: (m['l2'] ?? '') as String?,
        mobile: (m['m'] ?? '') as String?,
      );
    }).toList();
  }

  Future<List<PlaceLabel>> _readPlaces() async {
    try {
      final bytes = await _asset('tn_places.json.gz');
      final raw = utf8.decode(gzip.decode(bytes));
      final j = json.decode(raw) as Map<String, dynamic>;
      final list = (j['places'] as List?) ?? const [];
      return list
          .map((e) => PlaceLabel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<Uint8List> _asset(String name) async {
    final d = await rootBundle.load('assets/$name');
    return d.buffer.asUint8List();
  }

  Future<void> _readGraph() async {
    final bytes = await _asset('tn_roads.bin.gz');
    if (bytes.length < 64) {
      throw StateError('bundled road graph is empty');
    }
    // Inflate + build the routing adjacency index off the UI isolate. The
    // result comes back as TransferableTypedData, so nothing is copied.
    final parts = await Isolate.run<List<TransferableTypedData>>(
      () => _inflateAndIndex(bytes),
    );
    final raw = parts[0].materialize().asUint8List();
    final adjOffBytes = parts[1].materialize().asUint8List();
    final adjEdgeBytes = parts[2].materialize().asUint8List();
    graphRawBytes = raw.length;

    final g = RoadGraph.fromBytes(
      raw,
      adjacencyOffsets: Int32List.view(
        adjOffBytes.buffer,
        adjOffBytes.offsetInBytes,
        adjOffBytes.length ~/ 4,
      ),
      adjacencyEdges: Int32List.view(
        adjEdgeBytes.buffer,
        adjEdgeBytes.offsetInBytes,
        adjEdgeBytes.length ~/ 4,
      ),
    );
    graphNodes = g.nodeCount;
    graphEdges = g.edgeCount;
    if (g.isEmpty) {
      throw StateError('bundled road graph has no roads');
    }
    _graph = g;
    _router = OfflineRouter(g);
  }
}

/// Inflates the bundled graph and builds the CSR adjacency index.
///
/// Runs on a background isolate: this is the expensive part of loading the
/// map (gunzip + ~4 M index writes) and it must never block the UI.
List<TransferableTypedData> _inflateAndIndex(Uint8List compressed) {
  final raw = Uint8List.fromList(gzip.decode(compressed));
  final bd = ByteData.sublistView(raw);
  final n = bd.getUint32(8, Endian.little);
  final e = bd.getUint32(12, Endian.little);
  final edgeOff = 48 + n * 8;
  final edgeI32 = Int32List.view(
    raw.buffer,
    raw.offsetInBytes + edgeOff,
    e * 4,
  );

  final counts = Int32List(n + 1);
  for (var i = 0; i < e; i++) {
    counts[edgeI32[i * 4] + 1]++;
    counts[edgeI32[i * 4 + 1] + 1]++;
  }
  for (var i = 0; i < n; i++) {
    counts[i + 1] += counts[i];
  }
  final cursor = Int32List.fromList(counts);
  final adj = Int32List(e * 2);
  for (var i = 0; i < e; i++) {
    adj[cursor[edgeI32[i * 4]]++] = i;
    adj[cursor[edgeI32[i * 4 + 1]]++] = i;
  }

  return [
    TransferableTypedData.fromList([raw]),
    TransferableTypedData.fromList([counts.buffer.asUint8List()]),
    TransferableTypedData.fromList([adj.buffer.asUint8List()]),
  ];
}
