class SosCase {
  final String id;
  final String userId;
  final String? userEmail;
  final String? locationLink;
  final String? latitude;
  final String? longitude;
  final String status;
  final String notes;
  final String? videoUrl;
  final String? audioUrl;
  final String? triggerType;
  final DateTime? timestamp;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  // Tamil Nadu: nearest police station snapshot (nullable, backward-compat)
  final String? nearestPoliceStationName;
  final String? nearestPoliceStationAddress;
  final double? nearestPoliceStationLat;
  final double? nearestPoliceStationLng;
  final int? nearestPoliceStationDistanceM;
  final int? nearestPoliceStationOsmId;
  final String? nearestPoliceStationOsmType;
  final DateTime? nearestPoliceStationFetchedAt;

  const SosCase({
    required this.id,
    required this.userId,
    this.userEmail,
    this.locationLink,
    this.latitude,
    this.longitude,
    required this.status,
    this.notes = '',
    this.videoUrl,
    this.audioUrl,
    this.triggerType,
    this.timestamp,
    this.createdAt,
    this.updatedAt,
    this.nearestPoliceStationName,
    this.nearestPoliceStationAddress,
    this.nearestPoliceStationLat,
    this.nearestPoliceStationLng,
    this.nearestPoliceStationDistanceM,
    this.nearestPoliceStationOsmId,
    this.nearestPoliceStationOsmType,
    this.nearestPoliceStationFetchedAt,
  });

  factory SosCase.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic v) {
      if (v == null) return null;
      return DateTime.tryParse(v.toString());
    }

    return SosCase(
      id: json['id']?.toString() ?? '',
      userId: (json['userId'] ?? json['user_id'])?.toString() ?? '',
      userEmail: json['userEmail'] ?? json['user_email'],
      locationLink: json['locationLink'] ?? json['location_link'],
      latitude: json['latitude']?.toString(),
      longitude: json['longitude']?.toString(),
      status: json['status'] ?? 'Pending',
      notes: json['notes'] ?? '',
      videoUrl: json['videoUrl'] ?? json['video_url'],
      audioUrl: json['audioUrl'] ?? json['audio_url'],
      triggerType: json['triggerType'] ?? json['trigger_type'],
      timestamp: parseDate(json['timestamp'] ?? json['createdAt'] ?? json['created_at']),
      createdAt: parseDate(json['createdAt'] ?? json['created_at']),
      updatedAt: parseDate(json['updatedAt'] ?? json['updated_at']),
      nearestPoliceStationName: json['nearestPoliceStationName'] ?? json['nearest_police_station_name'],
      nearestPoliceStationAddress: json['nearestPoliceStationAddress'] ?? json['nearest_police_station_address'],
      nearestPoliceStationLat: (json['nearestPoliceStationLat'] ?? json['nearest_police_station_lat']) != null
          ? double.tryParse('${json['nearestPoliceStationLat'] ?? json['nearest_police_station_lat']}')
          : null,
      nearestPoliceStationLng: (json['nearestPoliceStationLng'] ?? json['nearest_police_station_lng']) != null
          ? double.tryParse('${json['nearestPoliceStationLng'] ?? json['nearest_police_station_lng']}')
          : null,
      nearestPoliceStationDistanceM: (json['nearestPoliceStationDistanceM'] ?? json['nearest_police_station_distance_m']) != null
          ? int.tryParse('${json['nearestPoliceStationDistanceM'] ?? json['nearest_police_station_distance_m']}')
          : null,
      nearestPoliceStationOsmId: (json['nearestPoliceStationOsmId'] ?? json['nearest_police_station_osm_id']) != null
          ? int.tryParse('${json['nearestPoliceStationOsmId'] ?? json['nearest_police_station_osm_id']}')
          : null,
      nearestPoliceStationOsmType: json['nearestPoliceStationOsmType'] ?? json['nearest_police_station_osm_type'],
      nearestPoliceStationFetchedAt: parseDate(json['nearestPoliceStationFetchedAt'] ?? json['nearest_police_station_fetched_at']),
    );
  }

  bool get isPending => status == 'Pending';

  bool get hasLiveLocation =>
      isPending && updatedAt != null && createdAt != null && updatedAt!.isAfter(createdAt!);

  bool get hasNearestStation =>
      nearestPoliceStationLat != null && nearestPoliceStationLng != null;

  String? get nearestStationDistanceLabel {
    final m = nearestPoliceStationDistanceM;
    if (m == null) return null;
    if (m < 1000) return '$m m away';
    return '${(m / 1000).toStringAsFixed(1)} km away';
  }

  SosCase copyWith({
    String? status,
    String? notes,
    DateTime? updatedAt,
  }) {
    return SosCase(
      id: id,
      userId: userId,
      userEmail: userEmail,
      locationLink: locationLink,
      latitude: latitude,
      longitude: longitude,
      status: status ?? this.status,
      notes: notes ?? this.notes,
      videoUrl: videoUrl,
      audioUrl: audioUrl,
      triggerType: triggerType,
      timestamp: timestamp,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      nearestPoliceStationName: nearestPoliceStationName,
      nearestPoliceStationAddress: nearestPoliceStationAddress,
      nearestPoliceStationLat: nearestPoliceStationLat,
      nearestPoliceStationLng: nearestPoliceStationLng,
      nearestPoliceStationDistanceM: nearestPoliceStationDistanceM,
      nearestPoliceStationOsmId: nearestPoliceStationOsmId,
      nearestPoliceStationOsmType: nearestPoliceStationOsmType,
      nearestPoliceStationFetchedAt: nearestPoliceStationFetchedAt,
    );
  }
}
