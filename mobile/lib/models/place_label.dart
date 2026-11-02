/// A city / town / district label drawn on the offline map.
class PlaceLabel {
  const PlaceLabel({
    required this.name,
    required this.lat,
    required this.lng,
    this.rank = 3,
  });

  final String name;
  final double lat;
  final double lng;

  /// 1 = city, 2 = municipality, 3 = town, 4 = village.
  final int rank;

  factory PlaceLabel.fromJson(Map<String, dynamic> j) => PlaceLabel(
        name: (j['n'] ?? '').toString(),
        lat: (j['la'] as num?)?.toDouble() ?? 0,
        lng: (j['lo'] as num?)?.toDouble() ?? 0,
        rank: (j['r'] as num?)?.toInt() ?? 3,
      );
}
