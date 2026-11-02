import 'package:dio/dio.dart';

import '../core/api_client.dart';
import '../models/app_user.dart';

class AuthService {
  final _api = ApiClient.instance;

  Future<Map<String, dynamic>> register({
    required String name,
    required String personalEmail,
    required String password,
  }) async {
    final response = await _api.post('/auth/register', {
      'name': name,
      'personalEmail': personalEmail,
      'password': password,
    });
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<Map<String, dynamic>> verifyOtp({
    required String personalEmail,
    required String otp,
  }) async {
    final response = await _api.post('/auth/verify-otp', {
      'personalEmail': personalEmail,
      'otp': otp,
    });
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<Map<String, dynamic>> resendOtp({
    required String personalEmail,
  }) async {
    final response = await _api.post('/auth/resend-otp', {
      'personalEmail': personalEmail,
    });
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<({String token, AppUser user})> login({
    required String email,
    required String password,
  }) async {
    final response = await _api.post('/auth/login', {
      'email': email,
      'password': password,
    });
    final data = Map<String, dynamic>.from(response.data as Map);
    return (
      token: data['token'] as String,
      user: AppUser.fromJson(
        Map<String, dynamic>.from(data['user'] as Map),
      ),
    );
  }

  Future<AppUser?> fetchMe() async {
    try {
      final response = await _api.get('/auth/me');
      final data = Map<String, dynamic>.from(response.data as Map);
      return AppUser.fromJson(Map<String, dynamic>.from(data['user'] as Map));
    } on DioException catch (e) {
      // Only an affirmative 401 means "unauthorized" (session expired).
      // Network/timeout/connection errors and 5xx must propagate so the
      // caller can preserve the cached session instead of wiping it.
      if (e.response?.statusCode == 401) {
        return null;
      }
      rethrow;
    }
  }
}
