import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:zelda_guardian/models/police_station.dart';
import 'package:zelda_guardian/services/offline_router.dart';
import 'package:zelda_guardian/services/road_graph.dart';

/// End-to-end check against the REAL bundled assets.
///
/// If this passes, the app can genuinely work with no network: the directory
/// and the road graph are inside the APK and the router can produce a real
/// turn-by-turn route between two points in Tamil Nadu.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled directory loads and is usable', () async {
    final bytes = await rootBundle.load('assets/tn_stations.json.gz');
    final raw = utf8.decode(gzip.decode(bytes.buffer.asUint8List()));
    final j = json.decode(raw) as Map<String, dynamic>;
    final list = (j['stations'] as List?) ?? const [];
    expect(list.length, greaterThan(1000));

    final withCoords = list.where((e) {
      final m = Map<String, dynamic>.from(e as Map);
      return m['lat'] != null && m['lng'] != null;
    }).toList();
    expect(withCoords.length, greaterThan(1000));

    final districts = list
        .map((e) => (e as Map)['district'])
        .where((d) => d != null)
        .toSet();
    expect(districts.length, greaterThan(30));
  });

  test('the bundled road graph is a real, connected map', () async {
    final bytes = await rootBundle.load('assets/tn_roads.bin.gz');
    expect(bytes.lengthInBytes, greaterThan(200000),
        reason: 'the road graph asset looks empty');
    final raw = gzip.decode(bytes.buffer.asUint8List());
    final g = RoadGraph.fromBytes(Uint8List.fromList(raw));

    expect(g.nodeCount, greaterThan(100000));
    expect(g.edgeCount, greaterThan(150000));
    expect(g.isEmpty, isFalse);

    // every edge must point at real nodes
    for (var e = 0; e < g.edgeCount; e += 977) {
      expect(g.edgeA(e), lessThan(g.nodeCount));
      expect(g.edgeB(e), lessThan(g.nodeCount));
      expect(g.edgeMetresRaw(e), greaterThan(0));
    }

    // the grid index must cover the edges
    final sink = Int32ListSink();
    g.edgesInBox(7.9, 76.0, 13.7, 80.7, sink);
    expect(sink.length, g.edgeCount,
        reason: 'the whole state should be reachable through the grid');
  });

  test('the on-device router produces a real route across Tamil Nadu',
      () async {
    final bytes = await rootBundle.load('assets/tn_roads.bin.gz');
    final g = RoadGraph.fromBytes(Uint8List.fromList(gzip.decode(bytes.buffer.asUint8List())));
    final router = OfflineRouter(g);

    // Chennai -> Coimbatore
    final route = router.between(
      from: const LatLng(13.0827, 80.2707),
      to: const LatLng(11.0168, 76.9558),
      mode: TravelMode.car,
    );
    expect(route, isNotNull);
    expect(route!.metres, greaterThan(300000));   // > 300 km by road
    expect(route.metres, lessThan(600000));       // < 600 km by road
    expect(route.geometry.length, greaterThan(50));
    expect(route.steps.length, greaterThan(3));
    expect(route.steps.last.type, 'arrive');
    expect(route.seconds, greaterThan(0));
  });

  test('routing finds the nearest police station by road', () async {
    final bytes = await rootBundle.load('assets/tn_roads.bin.gz');
    final g = RoadGraph.fromBytes(Uint8List.fromList(gzip.decode(bytes.buffer.asUint8List())));
    final router = OfflineRouter(g);

    // A point in the middle of Trichy.
    const start = LatLng(10.7905, 78.7047);
    final targets = <RouterTarget>[];
    final stations = <PoliceStation>[];

    final sbytes = await rootBundle.load('assets/tn_stations.json.gz');
    final sj = json.decode(utf8.decode(gzip.decode(sbytes.buffer.asUint8List())))
        as Map<String, dynamic>;
    for (final e in (sj['stations'] as List)) {
      final m = Map<String, dynamic>.from(e as Map);
      final lat = (m['lat'] as num?)?.toDouble();
      final lng = (m['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      if ((lat - start.latitude).abs() > 0.5) continue;
      if ((lng - start.longitude).abs() > 0.5) continue;
      final snaps = router.snap(LatLng(lat, lng), k: 1);
      if (snaps.isEmpty) continue;
      targets.add(RouterTarget(
        node: snaps.first.node,
        offRoadMetres: snaps.first.metres,
        payloadIndex: stations.length,
      ));
      stations.add(PoliceStation(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? 'PS').toString(),
        district: (m['district'] ?? '').toString(),
        lat: lat,
        lng: lng,
      ));
    }

    expect(targets.length, greaterThan(3),
        reason: 'expected several police stations near Trichy');

    final hit = router.nearest(
      from: start,
      targets: targets,
      mode: TravelMode.car,
    );
    expect(hit, isNotNull);
    final route = hit!.route;
    expect(route.metres, greaterThan(100));
    expect(route.metres, lessThan(30000), reason: 'nearest station in a city');
    expect(route.geometry.length, greaterThan(1));
  });

  test('each travel mode gives a different answer', () async {
    final bytes = await rootBundle.load('assets/tn_roads.bin.gz');
    final g = RoadGraph.fromBytes(Uint8List.fromList(gzip.decode(bytes.buffer.asUint8List())));
    final router = OfflineRouter(g);
    // a short trip inside a city, on ordinary streets
    const from = LatLng(10.7905, 78.7047);
    const to = LatLng(10.8000, 78.6950);

    final car = router.between(from: from, to: to, mode: TravelMode.car);
    final bike = router.between(from: from, to: to, mode: TravelMode.bike);
    final walk = router.between(from: from, to: to, mode: TravelMode.walk);
    expect(car, isNotNull);
    expect(bike, isNotNull);
    expect(walk, isNotNull);
    if (car == null || bike == null || walk == null) return;
    expect(walk.seconds, greaterThan(bike.seconds));
    expect(bike.seconds, greaterThan(car.seconds));
    // roughly the same roads, so a similar distance for everyone
    expect(walk.metres, closeTo(car.metres, car.metres * 0.2));
  });
}
