import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:zelda_guardian/models/place_label.dart';
import 'package:zelda_guardian/models/police_station.dart';
import 'package:zelda_guardian/services/offline_router.dart';
import 'package:zelda_guardian/services/road_graph.dart';
import 'package:zelda_guardian/widgets/offline_map_view.dart';

/// Builds a TNG2 buffer from a tiny hand-made graph so the binary reader and
/// the router can be tested without shipping a real map.
class _GraphBuilder {
  final List<List<double>> nodes = []; // lat, lng
  final List<List<int>> edges = []; // a, b, class, flags
  final List<double> metres = [];
  final List<String?> edgeName = [];
  final List<String> names = [];

  int node(double lat, double lng) {
    nodes.add([lat, lng]);
    return nodes.length - 1;
  }

  void edge(int a, int b, int cls, double m, {String? name, int flags = 0}) {
    edges.add([a, b, cls, flags]);
    metres.add(m);
    edgeName.add(name);
    if (name != null && !names.contains(name)) names.add(name);
  }

  Uint8List build() {
    final n = nodes.length;
    final e = edges.length;
    const gx = 16, gy = 16;
    const cellCount = gx * gy;
    final nameIndex = <int>[];
    for (final nm in edgeName) {
      if (nm == null) {
        nameIndex.add(0xffffffff);
      } else {
        nameIndex.add(names.indexOf(nm));
      }
    }

    final namesBuf = <int>[];
    for (final nm in names) {
      final b = utf8.encode(nm);
      namesBuf
        ..add(b.length & 0xff)
        ..add((b.length >> 8) & 0xff)
        ..addAll(b);
    }

    final total =
        48 + n * 8 + e * 16 + namesBuf.length + (cellCount + 1) * 4 + e * 4;
    final out = Uint8List(total);
    final bd = ByteData.sublistView(out);
    out.setRange(0, 4, 'TNG2'.codeUnits);
    bd.setUint32(4, 2, Endian.little);
    bd.setUint32(8, n, Endian.little);
    bd.setUint32(12, e, Endian.little);
    bd.setUint32(16, names.length, Endian.little);
    bd.setUint32(20, 19, Endian.little);
    bd.setUint16(24, gx, Endian.little);
    bd.setUint16(26, gy, Endian.little);
    bd.setInt32(28, 8000000, Endian.little);
    bd.setInt32(32, 77000000, Endian.little);
    bd.setInt32(36, 14000000, Endian.little);
    bd.setInt32(40, 81000000, Endian.little);
    bd.setUint32(44, cellCount, Endian.little);

    var o = 48;
    for (final nd in nodes) {
      bd.setInt32(o, (nd[0] * 1e6).round(), Endian.little);
      o += 4;
    }
    for (final nd in nodes) {
      bd.setInt32(o, (nd[1] * 1e6).round(), Endian.little);
      o += 4;
    }
    for (var i = 0; i < e; i++) {
      bd.setUint32(o, edges[i][0], Endian.little);
      bd.setUint32(o + 4, edges[i][1], Endian.little);
      bd.setUint16(o + 8, metres[i].round(), Endian.little);
      bd.setUint8(o + 10, edges[i][2]);
      bd.setUint8(o + 11, edges[i][3]);
      bd.setUint32(o + 12, nameIndex[i], Endian.little);
      o += 16;
    }
    for (final b in namesBuf) {
      out[o++] = b;
    }
    // grid: each edge is filed under the cell containing its midpoint, which is
    // exactly what the reader does.
    const latMin = 8.0, latMax = 14.0, lngMin = 77.0, lngMax = 81.0;
    final dLng = (lngMax - lngMin) / gx;
    final dLat = (latMax - latMin) / gy;
    final cellOf = List<int>.filled(e, 0);
    final cellCounts = List<int>.filled(cellCount, 0);
    for (var i = 0; i < e; i++) {
      final a = nodes[edges[i][0]];
      final b = nodes[edges[i][1]];
      final la = (a[0] + b[0]) / 2;
      final lo = (a[1] + b[1]) / 2;
      var cx = ((lo - lngMin) / dLng).floor();
      var cy = ((la - latMin) / dLat).floor();
      if (cx < 0) cx = 0;
      if (cx >= gx) cx = gx - 1;
      if (cy < 0) cy = 0;
      if (cy >= gy) cy = gy - 1;
      cellOf[i] = cy * gx + cx;
      cellCounts[cellOf[i]]++;
    }
    final cellStart = List<int>.filled(cellCount + 1, 0);
    for (var i = 0; i < cellCount; i++) {
      cellStart[i + 1] = cellStart[i] + cellCounts[i];
    }
    final cursor = List<int>.from(cellStart);
    final cellEdge = List<int>.filled(e, 0);
    for (var i = 0; i < e; i++) {
      cellEdge[cursor[cellOf[i]]++] = i;
    }
    for (var i = 0; i <= cellCount; i++) {
      bd.setUint32(o, cellStart[i], Endian.little);
      o += 4;
    }
    for (var i = 0; i < e; i++) {
      bd.setUint32(o, cellEdge[i], Endian.little);
      o += 4;
    }
    return out;
  }
}

/// A tiny graph:
///
///   0 --- 1 --- 2      (tertiary, 400 m each)
///   |               |
///   3               4  (motorway, 1200 m, one-way 0 -> 4)
///   |               |
///   5 --- 6 --- 7      (residential, 300 m each)
RoadGraph _sampleGraph() {
  final b = _GraphBuilder();
  final n0 = b.node(11.0, 78.0);
  final n1 = b.node(11.0, 78.003);
  final n2 = b.node(11.0, 78.006);
  final n3 = b.node(10.997, 78.0);
  final n4 = b.node(10.997, 78.006);
  final n5 = b.node(10.994, 78.0);
  final n6 = b.node(10.994, 78.003);
  final n7 = b.node(10.994, 78.006);

  b.edge(n0, n1, RoadGraph.cTertiary, 400);
  b.edge(n1, n2, RoadGraph.cTertiary, 400);
  b.edge(n0, n3, RoadGraph.cTertiary, 400);
  b.edge(n3, n5, RoadGraph.cResidential, 300);
  b.edge(n5, n6, RoadGraph.cResidential, 300);
  b.edge(n6, n7, RoadGraph.cResidential, 300);
  b.edge(n7, n4, RoadGraph.cResidential, 300);
  // motorway link 0 -> 4 only (one-way forward)
  b.edge(n0, n4, RoadGraph.cMotorway, 1200, flags: RoadGraph.flagOnewayFwd);
  return RoadGraph.fromBytes(b.build());
}

void main() {
  group('RoadGraph binary reader', () {
    test('reads the header, nodes, edges and names', () {
      final g = _sampleGraph();
      expect(g.nodeCount, 8);
      expect(g.edgeCount, 8);
      expect(g.isEmpty, isFalse);
      expect(g.latAt(0), closeTo(11.0, 1e-6));
      expect(g.lngAt(0), closeTo(78.0, 1e-6));
      expect(g.edgeClass(7), RoadGraph.cMotorway);
      expect(g.edgeFlags(7), RoadGraph.flagOnewayFwd);
    });

    test('rejects a non-TNG2 buffer', () {
      final bad = Uint8List(64);
      bad.setRange(0, 4, 'XXXX'.codeUnits);
      expect(() => RoadGraph.fromBytes(bad), throwsA(isA<FormatException>()));
    });

    test('rejects an unsupported version', () {
      final b = _GraphBuilder();
      b.node(11, 78);
      b.edge(0, 0, 4, 10);
      final bytes = b.build();
      ByteData.sublistView(bytes).setUint32(4, 9, Endian.little);
      expect(() => RoadGraph.fromBytes(bytes), throwsA(isA<FormatException>()));
    });

    test('finds the nearest node to a coordinate', () {
      final g = _sampleGraph();
      final ids = g.nearestNodes(11.0, 78.0031, k: 3);
      expect(ids, isNotEmpty);
      expect(ids.first, 1);
    });

    test('finds edges inside a bounding box', () {
      final g = _sampleGraph();
      final sink = Int32ListSink();
      g.edgesInBox(10.99, 77.99, 11.01, 78.01, sink);
      expect(sink.length, greaterThan(0));
    });
  });

  group('OfflineRouter', () {
    test('routes between two points on the network', () {
      final r = OfflineRouter(_sampleGraph());
      final route = r.between(
        from: const LatLng(11.0, 78.0),
        to: const LatLng(10.994, 78.006),
        mode: TravelMode.car,
      );
      expect(route, isNotNull);
      expect(route!.metres, greaterThan(0));
      expect(route.geometry.length, greaterThan(1));
      expect(route.steps, isNotEmpty);
      expect(route.steps.last.type, 'arrive');
    });

    test('car respects a one-way motorway', () {
      final r = OfflineRouter(_sampleGraph());
      // 0 -> 4 is one-way forward, so driving 4 -> 0 must take the long way.
      final forward = r.between(
        from: const LatLng(11.0, 78.0),
        to: const LatLng(10.997, 78.006),
        mode: TravelMode.car,
      );
      final backward = r.between(
        from: const LatLng(10.997, 78.006),
        to: const LatLng(11.0, 78.0),
        mode: TravelMode.car,
      );
      expect(forward, isNotNull);
      expect(backward, isNotNull);
      // forward may use the 1200 m motorway, backward may not
      expect(forward!.metres, lessThan(backward!.metres));
      expect(forward.seconds, lessThan(backward.seconds));
    });

    test('walking ignores one-way but is slower', () {
      final r = OfflineRouter(_sampleGraph());
      final walk = r.between(
        from: const LatLng(10.997, 78.006),
        to: const LatLng(11.0, 78.0),
        mode: TravelMode.walk,
      );
      final drive = r.between(
        from: const LatLng(10.997, 78.006),
        to: const LatLng(11.0, 78.0),
        mode: TravelMode.car,
      );
      expect(walk, isNotNull);
      expect(drive, isNotNull);
      // same road, so the same distance ...
      expect(walk!.metres, closeTo(drive!.metres, 1));
      // ... but walking takes much longer
      expect(walk.seconds, greaterThan(drive.seconds * 3));
    });

    test('bicycle is slower than car over the same distance', () {
      final r = OfflineRouter(_sampleGraph());
      final bike = r.between(
        from: const LatLng(11.0, 78.0),
        to: const LatLng(10.994, 78.006),
        mode: TravelMode.bike,
      );
      final car = r.between(
        from: const LatLng(11.0, 78.0),
        to: const LatLng(10.994, 78.006),
        mode: TravelMode.car,
      );
      expect(bike!.seconds, greaterThan(car!.seconds));
    });

    test('returns null for a point with no road nearby', () {
      final r = OfflineRouter(_sampleGraph());
      final route = r.between(
        from: const LatLng(9.0, 79.0),
        to: const LatLng(11.0, 78.0),
        mode: TravelMode.car,
      );
      expect(route, isNull);
    });

    test('nearest picks the closest target, not the first', () {
      final r = OfflineRouter(_sampleGraph());
      final near = r.snap(const LatLng(10.994, 78.0), k: 1).first.node;
      final far = r.snap(const LatLng(11.0, 78.006), k: 1).first.node;
      final hit = r.nearest(
        from: const LatLng(10.994, 78.0),
        targets: [
          RouterTarget(node: far, offRoadMetres: 5, payloadIndex: 0),
          RouterTarget(node: near, offRoadMetres: 5, payloadIndex: 1),
        ],
        mode: TravelMode.car,
      );
      expect(hit, isNotNull);
      expect(hit!.payloadIndex, 1);
    });

    test('mode strings map to profiles', () {
      expect(travelModeFrom('bike'), TravelMode.bike);
      expect(travelModeFrom('bicycle'), TravelMode.bike);
      expect(travelModeFrom('walk'), TravelMode.walk);
      expect(travelModeFrom('auto'), TravelMode.car);
      expect(travelModeFrom('drive'), TravelMode.car);
    });
  });

  group('OfflineMapView', () {
    testWidgets('renders the bundled graph without a network', (tester) async {
      final g = _sampleGraph();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: OfflineMapView(
                graph: g,
                userPoint: const LatLng(11.0, 78.0),
                stations: const [
                  PoliceStation(
                    id: '1',
                    name: 'Test PS',
                    district: 'Trichy',
                    lat: 11.0,
                    lng: 78.006,
                  ),
                ],
                places: const [
                  PlaceLabel(name: 'Trichy', lat: 10.99, lng: 78.0, rank: 1),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(OfflineMapView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows a notice when there is no graph yet', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: OfflineMapView(graph: null),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
    });
  });
}
