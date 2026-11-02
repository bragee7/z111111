import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sos_executor.dart';

/// Dart side of the 3x-power-press SOS guard.
///
/// Killed-state path is fully native (PowerGuardService + PowerPressReceiver):
/// on 3x SCREEN_ON/OFF in 6s the receiver writes [pendingKey] into
/// FlutterSharedPreferences and relaunches the app. This class only:
///  1. ensures the native guard is running,
///  2. consumes a fresh pending trigger into [detections] (same 5s cancel
///     window via SosController.triggerSOS),
///  3. exposes enable/disable backed by the same pref the receiver reads.
class PowerSosService {
  PowerSosService._();

  static const MethodChannel _channel = MethodChannel('zelda/power_sos');

  /// Must match PowerPressReceiver.PENDING_KEY / ENABLED_KEY.
  static const pendingKey = 'zelda_power_sos_trigger';
  static const enabledKey = 'zelda_power_sos_enabled';

  /// Key stashing the pre-logout power-SOS flag so login can restore it.
  static const preLogoutKey = 'zelda_power_sos_enabled_prelogout';

  /// Pending triggers older than this are stale (e.g. consumed late).
  static const freshnessWindow = Duration(seconds: 60);

  static final StreamController<void> _detectionController =
      StreamController<void>.broadcast();

  static Stream<void> get detections => _detectionController.stream;

  static bool _initialized = false;

  /// Start the native guard (idempotent) and fire any fresh pending trigger.
  ///
  /// Also registers the live push from MainActivity ("onPowerSosTrigger") so
  /// a trigger fired while the app is already running reaches SosController
  /// without waiting for an app restart.
  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPowerSosTrigger') {
        if (!_detectionController.isClosed) _detectionController.add(null);
      }
    });
    try {
      await _channel.invokeMethod('startGuard');
    } catch (_) {
      // Native side missing (tests/iOS) — pending-key path still works.
    }
    try {
      // Flush any trigger that arrived before the handler was registered.
      await _channel.invokeMethod('notifyReady');
    } catch (_) {}
    await consumePendingTrigger();
  }

  /// Fire [detections] if the native side stashed a fresh trigger, e.g. while
  /// the app was fully killed. Returns true when a trigger fired.
  static Future<bool> consumePendingTrigger() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ts = prefs.getInt(pendingKey);
      if (ts == null) return false;
      await prefs.remove(pendingKey);
      final age = DateTime.now().millisecondsSinceEpoch - ts;
      if (age < 0 || age > freshnessWindow.inMilliseconds) return false;
      // A press that predates the confirmed cancellation is a replay, not a
      // new SOS. A press after the cancel (ts > cancelledAt) still works.
      final cancelledAt = prefs.getInt(SosExecutor.cancelledAtKey) ?? 0;
      final session = (prefs.getString(SosExecutor.sessionIdKey) ?? '').trim();
      final cancelledSession =
          (prefs.getString(SosExecutor.cancelledSessionIdKey) ?? '').trim();
      final replayOfCancelled =
          cancelledAt > 0 &&
          (session.isEmpty || session == cancelledSession) &&
          ts <= cancelledAt;
      if (replayOfCancelled) return false;
      if (!_detectionController.isClosed) _detectionController.add(null);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isEnabled() async {
    try {
      final enabled = await _channel.invokeMethod<bool>('isEnabled');
      if (enabled != null) return enabled;
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(enabledKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod('setEnabled', {'enabled': enabled});
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(enabledKey, enabled);
    } catch (_) {}
  }
}
