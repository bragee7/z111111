import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:zelda_guardian/models/police_station.dart';

/// Mirror of PoliceStationsProvider._distanceToRoute so the off-route
/// detection is covered by a test.
double distanceToRoute(LatLng p, List<LatLng> line) {
  if (line.length < 2) return double.infinity;
  const mPerDegLat = 110574.0;
  const mPerDegLon = 111320.0;
  final kx = math.cos(p.latitude * math.pi / 180) * mPerDegLon;
  const ky = mPerDegLat;
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

void main() {
  group('PoliceStation parsing', () {
    test('parses a full ERSS record', () {
      final s = PoliceStation.fromJson({
        'id': '272',
        'name': 'D1 Ranipet PS',
        'district': 'Ranipet',
        'stationname': 'D1 Ranipet PS',
        'stationcity': 'RANIPET',
        'stationdistrict': 'Ranipet',
        'stationaddress': 'AC Ranipet, Ranipet, Tamil Nadu',
        'stationphoneno': '04172270219',
        'stationlat': 12.9272451400757,
        'stationlng': 79.3303146362305,
      });
      expect(s.id, '272');
      expect(s.name, 'D1 Ranipet PS');
      expect(s.district, 'Ranipet');
      expect(s.city, 'RANIPET');
      expect(s.address, 'AC Ranipet, Ranipet, Tamil Nadu');
      expect(s.phone, '04172270219');
      expect(s.lat, closeTo(12.9272451400757, 1e-9));
      expect(s.hasCoords, isTrue);
      expect(s.hasPhone, isTrue);
      expect(s.point, isNotNull);
    });

    test('parses a name-only directory row (no details yet)', () {
      final s = PoliceStation.fromJson({
        'id': '999',
        'name': 'X1 Remote PS',
        'district': 'Nilgiris',
      });
      expect(s.name, 'X1 Remote PS');
      expect(s.district, 'Nilgiris');
      expect(s.hasCoords, isFalse);
      expect(s.hasPhone, isFalse);
      expect(s.point, isNull);
    });

    test('parses numeric-string lat/lng', () {
      final s = PoliceStation.fromJson({
        'name': 'S',
        'district': 'D',
        'stationlat': '11.0168',
        'stationlng': '76.9558',
      });
      expect(s.lat, closeTo(11.0168, 1e-9));
      expect(s.lng, closeTo(76.9558, 1e-9));
    });

    test('distance labels', () {
      final near = PoliceStation.fromJson({'name': 'n', 'district': 'd'}).copyWith(distanceM: 110);
      expect(near.distanceLabel, '110 m');
      final far = PoliceStation.fromJson({'name': 'n', 'district': 'd'}).copyWith(distanceM: 1570);
      expect(far.distanceLabel, '1.57 km');
    });
  });

  group('DistrictHelpline parsing', () {
    test('reads landline and mobile', () {
      final d = DistrictHelpline.fromJson({
        'districtname': 'Coimbatore',
        'landline1': '0422221010',
        'landline2': '',
        'mobile': '8939765100',
      });
      expect(d.district, 'Coimbatore');
      expect(d.callNumber, '0422221010');
      expect(d.displayLandline.contains('8939765100'), isTrue);
    });

    test('falls back to mobile when no landline', () {
      final d = DistrictHelpline.fromJson({
        'districtname': 'X',
        'landline1': '',
        'mobile': '9000000000',
      });
      expect(d.callNumber, '9000000000');
    });
  });

  group('Route parsing', () {
    test('parses geometry, steps and summary', () {
      final r = PoliceRoute.fromJson({
        'source': 'valhalla',
        'distance': 1569.0,
        'duration': 294.0,
        'geometry': [
          [11.016828, 76.955801],
          [11.017000, 76.956000],
        ],
        'steps': [
          {
            'type': 'start',
            'instruction': 'Drive west on North Coimbatore Flyover.',
            'street': 'Flyover',
            'distance': 12.0,
            'time': 3.0,
          },
          {
            'type': 'left',
            'instruction': 'Turn left onto NH181.',
            'street': 'NH181',
            'distance': 240.0,
            'time': 40.0,
          },
        ],
      });
      expect(r.source, 'valhalla');
      expect(r.km, closeTo(1.569, 0.001));
      expect(r.minutes, 5);
      expect(r.geometry.length, 2);
      expect(r.geometry.first, const LatLng(11.016828, 76.955801));
      expect(r.steps.length, 2);
      expect(r.steps.first.type, 'start');
      expect(r.steps.first.icon, '▶️');
      expect(r.steps.last.type, 'left');
      expect(r.steps.last.icon, '↰');
      expect(r.steps.last.distanceLabel, '240 m');
      expect(r.etaLabel.contains('AM') || r.etaLabel.contains('PM'), isTrue);
    });

    test('empty route is safe', () {
      final r = PoliceRoute.fromJson({'source': '', 'distance': 0, 'duration': 0});
      expect(r.geometry, isEmpty);
      expect(r.steps, isEmpty);
      expect(r.minutes, 1);
    });
  });

  group('RouteCandidate', () {
    test('holds both air and road distance', () {
      final c = RouteCandidate.fromJson({
        'name': 'B2 R.S Puram PS',
        'district': 'Coimbatore',
        'air': 1440.0,
        'road': 2261.0,
      });
      expect(c.name, 'B2 R.S Puram PS');
      expect(c.air, 1440.0);
      expect(c.road, 2261.0);
      // Straight-line ranking would have placed it 3rd; road ranking says 5th.
      expect(c.road - c.air, greaterThan(800));
    });
  });

  group('Off-route geometry', () {
    test('a point on the line is on-route', () {
      const line = [LatLng(11.0000, 76.9500), LatLng(11.0100, 76.9500)];
      final d = distanceToRoute(const LatLng(11.0050, 76.9500), line);
      expect(d, lessThan(120));
    });

    test('a point far from the line is off-route', () {
      const line = [LatLng(11.0000, 76.9500), LatLng(11.0100, 76.9500)];
      final d = distanceToRoute(const LatLng(11.0050, 76.9700), line);
      expect(d, greaterThan(120));
    });

    test('a point beyond the end of the line is off-route', () {
      const line = [LatLng(11.0000, 76.9500), LatLng(11.0100, 76.9500)];
      final d = distanceToRoute(const LatLng(11.0300, 76.9500), line);
      expect(d, greaterThan(120));
    });
  });
}
