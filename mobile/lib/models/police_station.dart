import 'package:latlong2/latlong.dart';

/// A single Tamil Nadu police station.
///
/// The directory endpoint returns name + id for every station; the detail
/// fields (address, phone, coordinates) are filled in by the backend's
/// hydrator sweep and are therefore optional.
class PoliceStation {
  final String id;
  final String name;
  final String district;

  final String? city;
  final String? address;
  final String? phone;
  final double? lat;
  final double? lng;

  /// Straight-line distance from the user, in metres. Set client-side.
  final double? distanceM;

  const PoliceStation({
    required this.id,
    required this.name,
    required this.district,
    this.city,
    this.address,
    this.phone,
    this.lat,
    this.lng,
    this.distanceM,
  });

  factory PoliceStation.fromJson(Map<String, dynamic> j) {
    double? dbl(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      final parsed = double.tryParse(v.toString());
      return parsed;
    }

    return PoliceStation(
      id: (j['id'] ?? j['stationid'] ?? '').toString(),
      name: (j['stationname'] ?? j['name'] ?? 'Police Station').toString(),
      district: (j['stationdistrict'] ?? j['district'] ?? 'Unknown').toString(),
      city: (j['stationcity'] ?? j['city'])?.toString(),
      address: (j['stationaddress'] ?? j['address'])?.toString(),
      phone: (j['stationphoneno'] ?? j['phone'])?.toString(),
      lat: dbl(j['stationlat'] ?? j['lat']),
      lng: dbl(j['stationlng'] ?? j['lng']),
    );
  }

  PoliceStation copyWith({
    double? distanceM,
    String? city,
    String? address,
    String? phone,
    double? lat,
    double? lng,
  }) =>
      PoliceStation(
        id: id,
        name: name,
        district: district,
        city: city ?? this.city,
        address: address ?? this.address,
        phone: phone ?? this.phone,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        distanceM: distanceM ?? this.distanceM,
      );

  bool get hasCoords => lat != null && lng != null;
  bool get hasPhone => phone != null && phone!.trim().isNotEmpty;

  LatLng? get point {
    if (!hasCoords) return null;
    return LatLng(lat!, lng!);
  }

  /// A geo: intent that any installed map app can open. No Google involved.
  String get geoUri => 'geo:${lat ?? 0},${lng ?? 0}?q=${lat ?? 0},${lng ?? 0}'
      '%28${Uri.encodeComponent(name)}%29';

  /// Web link that does not require Google.
  String get osmLink =>
      'https://www.openstreetmap.org/?mlat=${lat ?? 0}&mlon=${lng ?? 0}#map=17/${lat ?? 0}/${lng ?? 0}';

  /// Plain coordinates, safe to paste into any chat.
  String get coordinatesText => hasCoords
      ? 'Lat ${lat!.toStringAsFixed(6)}, Lng ${lng!.toStringAsFixed(6)}'
      : '';

  /// Human-readable distance.
  String get distanceLabel {
    final d = distanceM;
    if (d == null) return '';
    if (d < 950) return '${(d / 10).round() * 10} m';
    return '${(d / 1000).toStringAsFixed(d < 9500 ? 2 : 1)} km';
  }

  @override
  String toString() => '$name ($district)';
}

/// A district helpline row.
class DistrictHelpline {
  final String district;
  final String? landline1;
  final String? landline2;
  final String? mobile;

  const DistrictHelpline({
    required this.district,
    this.landline1,
    this.landline2,
    this.mobile,
  });

  factory DistrictHelpline.fromJson(Map<String, dynamic> j) => DistrictHelpline(
        district: (j['districtname'] ?? '').toString(),
        landline1: (j['landline1'] ?? '')?.toString(),
        landline2: (j['landline2'] ?? '')?.toString(),
        mobile: (j['mobile'] ?? '')?.toString(),
      );

  String? get callNumber {
    if (landline1 != null && landline1!.trim().isNotEmpty) return landline1;
    if (mobile != null && mobile!.trim().isNotEmpty) return mobile;
    return null;
  }

  String get displayLandline {
    final l = landline1 ?? '';
    final m = mobile ?? '';
    if (l.isEmpty && m.isEmpty) return '—';
    if (l.isEmpty) return m;
    if (m.isEmpty) return l;
    return '$l  •  $m';
  }
}

/// One turn-by-turn manoeuvre.
class RouteStep {
  final String type; // start | straight | left | right | uturn | merge | roundabout | arrive | walk
  final String instruction;
  final String street;
  final double distance;
  final double time;

  const RouteStep({
    required this.type,
    required this.instruction,
    required this.street,
    required this.distance,
    required this.time,
  });

  factory RouteStep.fromJson(Map<String, dynamic> j) => RouteStep(
        type: (j['type'] ?? 'straight').toString(),
        instruction: (j['instruction'] ?? '').toString(),
        street: (j['street'] ?? '').toString(),
        distance: (j['distance'] ?? 0).toDouble(),
        time: (j['time'] ?? 0).toDouble(),
      );

  String get distanceLabel {
    if (distance < 950) return '${distance.round()} m';
    return '${(distance / 1000).toStringAsFixed(1)} km';
  }

  static const Map<String, String> icons = {
    'start': '▶️',
    'straight': '⬆️',
    'left': '↰',
    'right': '↱',
    'uturn': '↩️',
    'merge': '⤴️',
    'roundabout': '↻',
    'arrive': '🏁',
    'walk': '🚶',
  };

  String get icon => icons[type] ?? '⬆️';
}

/// A computed route.
class PoliceRoute {
  final String source;
  final double distance; // metres
  final double duration; // seconds
  final List<LatLng> geometry;
  final List<RouteStep> steps;
  final PoliceStation? destination;

  const PoliceRoute({
    required this.source,
    required this.distance,
    required this.duration,
    required this.geometry,
    required this.steps,
    this.destination,
  });

  factory PoliceRoute.fromJson(Map<String, dynamic> j, {PoliceStation? destination}) {
    final geo = (j['geometry'] as List?)
            ?.map((p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()))
            .toList() ??
        <LatLng>[];
    final steps = (j['steps'] as List?)
            ?.map((s) => RouteStep.fromJson(Map<String, dynamic>.from(s as Map)))
            .toList() ??
        <RouteStep>[];
    return PoliceRoute(
      source: (j['source'] ?? '').toString(),
      distance: (j['distance'] ?? 0).toDouble(),
      duration: (j['duration'] ?? 0).toDouble(),
      geometry: geo,
      steps: steps,
      destination: destination,
    );
  }

  int get minutes => (duration / 60).round().clamp(1, 9999);
  double get km => distance / 1000;

  String get distanceLabel =>
      '${km.toStringAsFixed(km < 10 ? 2 : 1)} km';

  String get etaLabel {
    final eta = DateTime.now().add(Duration(seconds: duration.round()));
    final h = eta.hour % 12 == 0 ? 12 : eta.hour % 12;
    final m = eta.minute.toString().padLeft(2, '0');
    return '$h:$m ${eta.hour >= 12 ? 'PM' : 'AM'}';
  }
}

/// Candidates returned by the shortest-road-route lookup.
class RouteCandidate {
  final String name;
  final String district;
  final double air; // straight-line metres
  final double road; // real road metres

  const RouteCandidate({
    required this.name,
    required this.district,
    required this.air,
    required this.road,
  });

  factory RouteCandidate.fromJson(Map<String, dynamic> j) => RouteCandidate(
        name: (j['name'] ?? '').toString(),
        district: (j['district'] ?? '').toString(),
        air: (j['air'] ?? 0).toDouble(),
        road: (j['road'] ?? 0).toDouble(),
      );
}
