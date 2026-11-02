import 'package:dio/dio.dart';

import '../core/api_client.dart';
import '../models/sos_case.dart';

class SosService {
  final _api = ApiClient.instance;

  Future<SosCase> createCase({
    required String videoPath,
    required String audioPath,
    required String locationLink,
    required String latitude,
    required String longitude,
    required String notes,
  }) async {
    final formData = FormData();
    if (videoPath.isNotEmpty) {
      formData.files.add(MapEntry(
        'video',
        await MultipartFile.fromFile(videoPath, filename: 'emergency-video.webm'),
      ));
    }
    // Audio rides along when present — including the audio-only fallback
    // (background recording without camera): the server accepts audio
    // without video (both URLs nullable).
    if (audioPath.isNotEmpty && audioPath != videoPath) {
      formData.files.add(MapEntry(
        'audio',
        await MultipartFile.fromFile(audioPath, filename: 'emergency-audio.m4a'),
      ));
    }
    formData.fields.addAll([
      MapEntry('locationLink', locationLink),
      MapEntry('latitude', latitude),
      MapEntry('longitude', longitude),
      MapEntry('notes', notes),
    ]);

    final response = await _api.dio.post(
      '/api/sos',
      data: formData,
      options: Options(contentType: 'multipart/form-data'),
    );
    final data = Map<String, dynamic>.from(response.data as Map);
    return SosCase.fromJson(Map<String, dynamic>.from(data['case'] as Map));
  }

  Future<List<SosCase>> getCases() async {
    final response = await _api.get('/sos');
    final data = Map<String, dynamic>.from(response.data as Map);
    final list = (data['cases'] as List? ?? []);
    return list
        .map((e) => SosCase.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<SosCase> getCase(String id) async {
    final response = await _api.get('/sos/$id');
    final data = Map<String, dynamic>.from(response.data as Map);
    return SosCase.fromJson(Map<String, dynamic>.from(data['case'] as Map));
  }

  Future<SosCase> updateCase(
    String id, {
    String? status,
    String? notes,
  }) async {
    final body = <String, dynamic>{
      'status': ?status,
      'notes': ?notes,
    };
    final response = await _api.put('/sos/$id', body);
    final data = Map<String, dynamic>.from(response.data as Map);
    return SosCase.fromJson(Map<String, dynamic>.from(data['case'] as Map));
  }

  Future<void> updateLocation(
    String id, {
    required String latitude,
    required String longitude,
    required String locationLink,
  }) async {
    await _api.put('/sos/$id/location', {
      'latitude': latitude,
      'longitude': longitude,
      'locationLink': locationLink,
    });
  }
}
