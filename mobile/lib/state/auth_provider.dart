import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';
import '../core/socket_service.dart';
import '../models/app_user.dart';
import '../services/auth_service.dart';
import '../services/power_sos_service.dart';
import '../services/voice_guard_service.dart';

class AuthProvider extends ChangeNotifier {
  static const _userKey = 'auth_user';

  final AuthService _authService = AuthService();
  final SocketService _socket = SocketService.instance;

  AppUser? _user;
  bool _loading = true;
  String? _restoreError;

  AppUser? get user => _user;
  bool get isLoading => _loading;
  bool get isAuthenticated => _user != null;
  String? get restoreError => _restoreError;

  Future<void> restoreSession() async {
    _loading = true;
    _restoreError = null;
    notifyListeners();

    final token = await ApiClient.getToken();
    if (token == null || token.isEmpty) {
      _user = null;
      _loading = false;
      notifyListeners();
      return;
    }

    // Load cached user first so a slow/hung network still leaves a session
    // visible (also covers the splash 15s TimeoutException path).
    try {
      _user = await _loadCachedUser();
    } catch (_) {
      // Corrupt cache is treated as no cache; network will decide.
      _user = null;
    }

    try {
      final me = await _authService
          .fetchMe()
          .timeout(const Duration(seconds: 10));
      if (me != null) {
        _user = me;
        await _saveUser(me);
        _restoreError = null;
        _connectSocket();
      } else {
        // Affirmative 401: session expired. Keep existing clear behavior.
        _user = null;
        await ApiClient.clearToken();
        await _clearCachedUser();
        _restoreError = 'Session expired. Please log in again.';
      }
    } on TimeoutException {
      // Network hung: preserve cached session + token.
      if (_user != null) {
        _restoreError = 'Connection slow. Showing saved session.';
        _connectSocket();
      } else {
        _restoreError =
            'Connection timed out. Check your network and retry.';
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        // Defensive: fetchMe normally maps 401 to null, but handle a
        // direct 401 throw the same way.
        _user = null;
        await ApiClient.clearToken();
        await _clearCachedUser();
        _restoreError = 'Session expired. Please log in again.';
      } else {
        // Network/timeout/500/etc: preserve cached session + token.
        if (_user != null) {
          _restoreError = 'Offline. Showing saved session.';
          _connectSocket();
        } else {
          _restoreError =
              'Cannot reach server. Check your network and retry.';
        }
      }
    } catch (_) {
      // Parsing or any other single-shot failure: never wipe on ambiguity.
      if (_user != null) {
        _restoreError = 'Offline. Showing saved session.';
        _connectSocket();
      } else {
        _restoreError =
            'Cannot reach server. Check your network and retry.';
      }
    }

    _loading = false;
    notifyListeners();
  }

  Future<void> login(String email, String password) async {
    final result = await _authService.login(email: email, password: password);
    await ApiClient.saveToken(result.token);
    _user = result.user;
    _restoreError = null;
    await _saveUser(result.user);
    await _restoreProtectionPrefs();
    _connectSocket();
    notifyListeners();
  }

  /// Restores voice/power protection flags stashed at logout.
  ///
  /// Logout clears both flags (no protection while logged out); without a
  /// restore, every logout->login cycle leaves protection silently OFF while
  /// the dashboard shows stale ON. Fresh installs (no stash) default to ON,
  /// matching first-run behavior. The dashboard auto-start then boots the
  /// engine from the restored pref.
  Future<void> _restoreProtectionPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final voiceStash = prefs.getBool(VoiceGuardService.preLogoutKey);
      final powerStash = prefs.getBool(PowerSosService.preLogoutKey);
      await VoiceGuardService.setEnabledPref(voiceStash ?? true);
      await PowerSosService.setEnabled(powerStash ?? true);
      await prefs.remove(VoiceGuardService.preLogoutKey);
      await prefs.remove(PowerSosService.preLogoutKey);
    } catch (_) {
      // Best-effort: dashboard auto-start heals a missed restore.
    }
  }

  Future<void> logout() async {
    _socket.disconnect();
    _user = null;
    _restoreError = null;
    await ApiClient.clearToken();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userKey);
    notifyListeners();
  }

  void _connectSocket() {
    _socket.connect(role: _user?.role);
  }

  Future<void> _saveUser(AppUser user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(user.toJson()));
  }

  Future<AppUser?> _loadCachedUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_userKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return AppUser.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearCachedUser() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userKey);
  }
}
