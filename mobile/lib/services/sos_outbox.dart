import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';
import '../models/sos_case.dart';
import 'sos_service.dart';

/// A failed SOS alert that is kept on the device until it can be delivered.
///
/// Alerts are stored as one SharedPreferences entry per alert (rather than a
/// single JSON list) so the background isolate can enqueue an alert while the
/// UI isolate is retrying another one without either write being lost.
class PendingSosAlert {
  final String id;
  final String sessionId;
  final String userId;
  final String notes;
  final String latitude;
  final String longitude;
  final String locationLink;
  final String videoPath;
  final String audioPath;
  final String source;
  final int createdAtMs;
  final int attempts;
  final int lastAttemptAtMs;
  final int nextAttemptAtMs;

  const PendingSosAlert({
    required this.id,
    required this.sessionId,
    required this.userId,
    required this.notes,
    required this.latitude,
    required this.longitude,
    required this.locationLink,
    required this.videoPath,
    required this.audioPath,
    required this.source,
    required this.createdAtMs,
    required this.attempts,
    required this.lastAttemptAtMs,
    required this.nextAttemptAtMs,
  });

  /// Stable, human-readable reference written into the case notes. It lets a
  /// retry recognise an alert that reached the server before the connection
  /// dropped (best-effort idempotency; no server schema change required).
  String get reference => 'ZELDA-$id';

  String get notesWithReference => '$notes\nRef: $reference';

  PendingSosAlert copyWith({
    int? attempts,
    int? lastAttemptAtMs,
    int? nextAttemptAtMs,
  }) {
    return PendingSosAlert(
      id: id,
      sessionId: sessionId,
      userId: userId,
      notes: notes,
      latitude: latitude,
      longitude: longitude,
      locationLink: locationLink,
      videoPath: videoPath,
      audioPath: audioPath,
      source: source,
      createdAtMs: createdAtMs,
      attempts: attempts ?? this.attempts,
      lastAttemptAtMs: lastAttemptAtMs ?? this.lastAttemptAtMs,
      nextAttemptAtMs: nextAttemptAtMs ?? this.nextAttemptAtMs,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'sessionId': sessionId,
    'userId': userId,
    'notes': notes,
    'latitude': latitude,
    'longitude': longitude,
    'locationLink': locationLink,
    'videoPath': videoPath,
    'audioPath': audioPath,
    'source': source,
    'createdAtMs': createdAtMs,
    'attempts': attempts,
    'lastAttemptAtMs': lastAttemptAtMs,
    'nextAttemptAtMs': nextAttemptAtMs,
  };

  factory PendingSosAlert.fromJson(Map<String, dynamic> json) {
    int asInt(dynamic value, [int fallback = 0]) =>
        value is int ? value : int.tryParse('${value ?? ''}') ?? fallback;
    String asString(dynamic value) => value?.toString() ?? '';

    return PendingSosAlert(
      id: asString(json['id']),
      sessionId: asString(json['sessionId']),
      userId: asString(json['userId']),
      notes: asString(json['notes']),
      latitude: asString(json['latitude']),
      longitude: asString(json['longitude']),
      locationLink: asString(json['locationLink']),
      videoPath: asString(json['videoPath']),
      audioPath: asString(json['audioPath']),
      source: asString(json['source']),
      createdAtMs: asInt(json['createdAtMs']),
      attempts: asInt(json['attempts']),
      lastAttemptAtMs: asInt(json['lastAttemptAtMs']),
      nextAttemptAtMs: asInt(json['nextAttemptAtMs']),
    );
  }
}

/// Durable outbox for SOS alerts that could not reach the backend.
///
/// The alert is copied to private app storage first, so evidence survives the
/// OS clearing the camera cache and the app being killed. A retry is attempted:
///   * once at app startup and every minute while the dashboard is open;
///   * every minute while the voice-protection foreground service is alive;
///   * with exponential backoff, for up to 24 hours / 12 attempts.
///
/// Delivery is at-least-once. Before creating a new case, a retry checks the
/// user's recent cases for this alert's [PendingSosAlert.reference] so a
/// dropped response does not duplicate the case in the common case.
class SosOutbox {
  SosOutbox._();

  static const _keyPrefix = 'zelda_sos_outbox_v1_';
  static const _lockKey = 'zelda_sos_outbox_lock_until';
  static const _lockMs = 4 * 60 * 1000;
  static const maxAgeMs = 24 * 60 * 60 * 1000;
  static const maxAttempts = 12;
  static const maxQueued = 5;

  /// Test seam: point media storage at a temporary directory.
  static Future<Directory> Function()? baseDirectoryOverride;

  /// Test seam: inject an auth token without secure-storage plugins.
  static Future<String?> Function()? tokenProviderOverride;

  static bool _retrying = false;

  static String _newId() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    final salt = Random().nextInt(0x7fffffff).toRadixString(16);
    return '${ms}_$salt';
  }

  static String _key(String id) => '$_keyPrefix$id';

  /// Read the cached auth user written by `AuthProvider` (`auth_user`).
  /// Keeping the outbox scoped to its owner prevents a queued alert from being
  /// sent under a different account after logout/login.
  static String _userIdFromPrefs(SharedPreferences prefs) {
    try {
      final raw = prefs.getString('auth_user');
      if (raw == null || raw.isEmpty) return '';
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return '';
      return decoded['id']?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<SharedPreferences> _prefs({bool reload = true}) async {
    final prefs = await SharedPreferences.getInstance();
    if (reload) {
      try {
        await prefs.reload();
      } catch (_) {}
    }
    return prefs;
  }

  static PendingSosAlert? _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final alert = PendingSosAlert.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      return alert.id.isEmpty ? null : alert;
    } catch (_) {
      return null;
    }
  }

  static Future<List<PendingSosAlert>> pending() async {
    final prefs = await _prefs();
    final alerts = <PendingSosAlert>[];
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_keyPrefix)) continue;
      final raw = prefs.getString(key);
      if (raw == null) continue;
      final alert = _decode(raw);
      if (alert != null) alerts.add(alert);
    }
    alerts.sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));
    return alerts;
  }

  static Future<int> pendingCount() async => (await pending()).length;

  /// Persist a failed alert. Returns the stored alert, or an existing one when
  /// this SOS session is already queued (the caller can therefore retry the
  /// same session safely).
  static Future<PendingSosAlert?> enqueue({
    required String sessionId,
    required String notes,
    required String latitude,
    required String longitude,
    required String locationLink,
    required String videoPath,
    required String audioPath,
    required String source,
    String? userId,
    int? createdAtMs,
  }) async {
    try {
      final prefs = await _prefs();
      final now = DateTime.now().millisecondsSinceEpoch;
      final existing = await pending();
      if (sessionId.isNotEmpty) {
        for (final alert in existing) {
          if (alert.sessionId == sessionId) return alert;
        }
      }

      // Drop expired rows first, then enforce a small storage cap.
      final keep = <PendingSosAlert>[];
      for (final alert in existing) {
        if (now - alert.createdAtMs > maxAgeMs) {
          await _removeAlert(prefs, alert);
        } else {
          keep.add(alert);
        }
      }
      while (keep.length >= maxQueued) {
        final oldest = keep.removeAt(0);
        await _removeAlert(prefs, oldest);
      }

      final id = _newId();
      final media = await _copyMedia(id, videoPath, audioPath);
      final alert = PendingSosAlert(
        id: id,
        sessionId: sessionId,
        userId: userId ?? _userIdFromPrefs(prefs),
        notes: notes,
        latitude: latitude,
        longitude: longitude,
        locationLink: locationLink,
        videoPath: media.video,
        audioPath: media.audio,
        source: source,
        createdAtMs: createdAtMs ?? now,
        // The failed live attempt counts as attempt #1.
        attempts: 1,
        lastAttemptAtMs: now,
        nextAttemptAtMs: now + _backoffMs(1),
      );
      await prefs.setString(_key(id), jsonEncode(alert.toJson()));
      return alert;
    } catch (_) {
      return null;
    }
  }

  /// Try every due alert once. Returns the cases that were delivered during
  /// this pass (newly created or recovered by reference).
  static Future<List<SosCase>> retryPending({SosService? service}) async {
    if (_retrying) return const [];
    _retrying = true;
    SharedPreferences? prefs;
    var lockValue = 0;
    try {
      prefs = await _prefs();
      final now = DateTime.now().millisecondsSinceEpoch;
      if ((prefs.getInt(_lockKey) ?? 0) > now) return const [];

      // Lease the retry loop so the UI and background isolates do not both
      // POST the same alert (best effort across two processes).
      lockValue = now + _lockMs;
      await prefs.setInt(_lockKey, lockValue);
      await prefs.reload();
      if ((prefs.getInt(_lockKey) ?? 0) != lockValue) return const [];

      final alerts = await pending();
      if (alerts.isEmpty) return const [];

      // Wait for a logged-in session instead of burning attempts against a
      // guaranteed 401. The alert stays queued for the next retry.
      final token = tokenProviderOverride != null
          ? await tokenProviderOverride!()
          : await ApiClient.getToken();
      if (token == null || token.isEmpty) return const [];

      // Never deliver another account's queued evidence.
      final currentUserId = _userIdFromPrefs(prefs);
      if (currentUserId.isEmpty) return const [];

      final svc = service ?? SosService();
      final delivered = <SosCase>[];
      for (final alert in alerts) {
        if (now - alert.createdAtMs > maxAgeMs ||
            alert.attempts >= maxAttempts) {
          await remove(alert.id);
          continue;
        }
        if (now < alert.nextAttemptAtMs) continue;
        if (alert.userId != currentUserId) continue;

        SosCase? existing;
        if (alert.attempts > 0) {
          try {
            final cases = await svc.getCases();
            for (final c in cases) {
              if (c.notes.contains(alert.reference)) {
                existing = c;
                break;
              }
            }
          } catch (_) {
            // Lookup is only an optimisation; fall through to create.
          }
        }

        if (existing != null) {
          await remove(alert.id);
          delivered.add(existing);
          continue;
        }

        final video = await _existingPath(alert.videoPath);
        final audio = await _existingPath(alert.audioPath);
        try {
          final created = await svc.createCase(
            videoPath: video,
            audioPath: audio,
            locationLink: alert.locationLink,
            latitude: alert.latitude,
            longitude: alert.longitude,
            notes: alert.notesWithReference,
          );
          await remove(alert.id);
          delivered.add(created);
        } on DioException catch (e) {
          final status = e.response?.statusCode;
          if (status == 401 || status == 403) {
            // Session expired/logged out: keep the alert for after login.
            break;
          }
          await _markFailed(alert, e.toString());
        } catch (e) {
          await _markFailed(alert, e.toString());
        }
      }
      return delivered;
    } catch (_) {
      return const [];
    } finally {
      _retrying = false;
      if (prefs != null && lockValue != 0) {
        try {
          if ((prefs.getInt(_lockKey) ?? 0) == lockValue) {
            await prefs.setInt(_lockKey, 0);
          }
        } catch (_) {}
      }
    }
  }

  /// Remove an alert and its private media copy.
  static Future<void> remove(String id) async {
    try {
      final prefs = await _prefs(reload: false);
      await prefs.remove(_key(id));
      await _deleteMedia(id);
    } catch (_) {}
  }

  static Future<void> _markFailed(PendingSosAlert alert, String error) async {
    try {
      final nextAttempts = alert.attempts + 1;
      final now = DateTime.now().millisecondsSinceEpoch;
      final updated = alert.copyWith(
        attempts: nextAttempts,
        lastAttemptAtMs: now,
        nextAttemptAtMs: now + _backoffMs(nextAttempts),
      );
      final prefs = await _prefs(reload: false);
      await prefs.setString(_key(alert.id), jsonEncode(updated.toJson()));
    } catch (_) {}
  }

  static Future<void> _removeAlert(
    SharedPreferences prefs,
    PendingSosAlert alert,
  ) async {
    try {
      await prefs.remove(_key(alert.id));
      await _deleteMedia(alert.id);
    } catch (_) {}
  }

  static int _backoffMs(int attempts) {
    if (attempts <= 1) return 30 * 1000;
    if (attempts == 2) return 2 * 60 * 1000;
    if (attempts == 3) return 5 * 60 * 1000;
    if (attempts == 4) return 15 * 60 * 1000;
    return 30 * 60 * 1000;
  }

  static Future<String> _existingPath(String path) async {
    if (path.isEmpty) return '';
    try {
      return await File(path).exists() ? path : '';
    } catch (_) {
      return '';
    }
  }

  static String _extension(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '';
    final ext = path.substring(dot);
    return ext.length <= 6 ? ext : '';
  }

  static Future<({String video, String audio})> _copyMedia(
    String id,
    String videoPath,
    String audioPath,
  ) async {
    try {
      final base =
          await (baseDirectoryOverride?.call() ??
              getApplicationSupportDirectory());
      final dir = Directory('${base.path}/sos_outbox/$id');
      await dir.create(recursive: true);

      Future<String> copy(String source, String name) async {
        if (source.isEmpty) return '';
        final file = File(source);
        if (!await file.exists()) return '';
        final target = '${dir.path}/$name${_extension(source)}';
        await file.copy(target);
        return target;
      }

      final video = await copy(videoPath, 'video');
      final audio = audioPath == videoPath
          ? video
          : await copy(audioPath, 'audio');
      return (video: video, audio: audio);
    } catch (_) {
      // If the private copy fails, keep the original path: a likely send is
      // better than dropping the evidence entirely.
      return (video: videoPath, audio: audioPath);
    }
  }

  static Future<void> _deleteMedia(String id) async {
    try {
      final base =
          await (baseDirectoryOverride?.call() ??
              getApplicationSupportDirectory());
      final dir = Directory('${base.path}/sos_outbox/$id');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}
