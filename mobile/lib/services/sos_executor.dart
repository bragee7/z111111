import 'dart:async';
import 'dart:math';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';
import '../state/sos_lifecycle.dart';
import 'location_service.dart';
import 'sos_outbox.dart';
import 'sos_service.dart';
import 'voice_guard_service.dart';

/// Authoritative SOS state machine that runs in the BACKGROUND isolate
/// (the flutter_background_service engine, already kept alive as a
/// microphone foreground service while voice protection is on, and booted
/// on-demand into executor-standby mode for power-button triggers).
///
/// Why this exists: every SOS timer (5s countdown,
/// 30s recording, 30s live tracking) used to live in the main-isolate
/// SosController, which is only born when the dashboard mounts. A voice or
/// power trigger fired while the app was closed could therefore only stash
/// a pending pref and wait for the user to open ZELDA. This executor owns
/// the whole countdown → recording → GPS → submit → upload → tracking chain
/// in the background isolate, mirrors every transition into prefs + a
/// broadcast event, and the Flutter UI only OBSERVES/synchronizes.
///
/// Single active SOS: a trigger arriving while one is in flight is answered
/// with a busy signal (surfaced as "SOS already in progress"), never a
/// second case.
class SosExecutor {
  SosExecutor._();

  // ── prefs mirror (consumed by native alarm/recording + Flutter UI) ──
  static const stateKey = 'zelda_sos_state';
  static const remainingKey = 'zelda_sos_remaining';
  static const sourceKey = 'zelda_sos_source';
  static const startedAtKey = 'zelda_sos_started_at';
  static const commandKey = 'zelda_sos_command';
  static const caseIdKey = 'zelda_sos_case_id';
  static const videoPathKey = 'zelda_sos_video_path';
  static const audioPathKey = 'zelda_sos_audio_path';
  static const audioOnlyKey = 'zelda_sos_audio_only';
  static const nativeCommandKey = 'zelda_sos_native_command';
  static const nativeDoneKey = 'zelda_sos_native_done';
  static const alarmRequestKey = 'zelda_sos_alarm_request';
  static const alarmHandledKey = 'zelda_sos_alarm_handled';
  // Sending-phase marker: written on entering 'sending', cleared on every
  // exit (sent / failed / cancel / fresh trigger / stale reset). Lets boot
  // reconcile distinguish "interrupted mid-send" from idle without auto-send.
  static const sendingAtKey = 'zelda_sos_sending_at';

  // ── session identity + cancellation fence ──
  // Every trigger (Dart local, BG executor, native claim) stamps a unique
  // session id. Cancelling writes the cancelled-session fence; any late
  // snapshot/callback/native tick for that session is then ignored while a
  // genuinely new SOS (new id) still works normally.
  static const sessionIdKey = 'zelda_sos_session_id';
  static const cancelledSessionIdKey = 'zelda_sos_cancelled_session_id';
  static const cancelledAtKey = 'zelda_sos_cancelled_at';
  static const cancelReasonKey = 'zelda_sos_cancel_reason';
  static const pendingVoiceTriggerKey = 'zelda_pending_sos_trigger';
  static const pendingPowerTriggerKey = 'zelda_power_sos_trigger';

  // ── cross-isolate invoke protocol (BG <-> main) ──
  static const sosStateEvent = 'sos_state';
  static const sosTriggerInvoke = 'sos_trigger';
  static const sosCancelInvoke = 'sos_cancel';
  static const sosStartAppRecording = 'sos_start_app_recording';
  static const sosAppRecordingDone = 'sos_app_recording_done';

  static const states = [
    'idle',
    'listening',
    'cancelWindow',
    'countdown',
    'recording',
    'sending',
    'sent',
  ];

  // ── BG-isolate runtime (per-isolate statics, touched only in BG) ──
  static ServiceInstance? _bgService;
  static bool Function()? _isForeground;
  static Timer? _tick;
  static Timer? _trackingTimer;
  static Timer? _outboxTimer;
  static String _trackingCaseId = '';

  /// Mic pause/resume hooks (bound by the voice engine in _onStart). The
  /// native background recording needs the microphone, so the executor
  /// pauses the KWS loop first and resumes it after the SOS send.
  static Future<void> Function()? onPauseMic;
  static Future<void> Function()? onResumeMic;

  static void bindMicHooks({
    required Future<void> Function() onPause,
    required Future<void> Function() onResume,
  }) {
    onPauseMic = onPause;
    onResumeMic = onResume;
  }

  static Future<void> _resumeMicBestEffort(String why) async {
    try {
      await onResumeMic?.call().timeout(const Duration(seconds: 15));
      await VoiceGuardService.flog('sosexec', 'mic resumed ($why)');
    } catch (e) {
      await VoiceGuardService.flog('sosexec', 'mic resume failed ($why): $e');
    }
  }

  static bool _active = false;
  static String _phase = 'idle';
  static int _remaining = 0;

  /// Wall-clock start of the current cancel countdown. The 5→1 steps are
  /// computed from elapsed time so each step lasts a full second no matter
  /// where the shared 1s poll tick happens to fall.
  static int _countdownStartMs = 0;
  static String _source = '';

  /// Session id owned by this BG isolate, mirrored on every broadcast so the
  /// UI can fence late snapshots even before the next disk poll.
  static String _activeSessionId = '';
  static int _busyNotifiedAt = 0;

  static String _newSessionId() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    final salt = Random().nextInt(0x7fffffff).toRadixString(16);
    return 'sos_${ms}_$salt';
  }

  /// Boot the executor inside the BG isolate. Cheap and infallible by
  /// design (prefs + timers only) — call FIRST in _onStart, before any
  /// mic/spotter work, so power-button triggers get a live executor even
  /// when voice listening is disabled.
  static Future<void> onBoot(
    ServiceInstance service,
    bool Function() isForeground,
  ) async {
    _bgService = service;
    _isForeground = isForeground;

    service.on(sosTriggerInvoke).listen((event) async {
      final source = (event?['source'] as String?)?.trim();
      await onTrigger(source == null || source.isEmpty ? 'app' : source);
    });
    service.on(sosCancelInvoke).listen((_) async {
      await onCancel(fromInvoke: true);
    });
    service.on(sosAppRecordingDone).listen((event) async {
      final path = (event?['videoPath'] as String?) ?? '';
      final err = (event?['error'] as String?) ?? '';
      await onAppRecordingDone(
        path.isEmpty ? null : path,
        err.isEmpty ? null : err,
      );
    });
    service.on(VoiceGuardService.resetCooldownEventName).listen((_) {
      // Cooldown reset doubles as "new utterance allowed" — if no SOS is
      // active there is nothing to do; the dedupe timestamps live in the
      // voice engine itself.
    });

    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_poll());
    });
    _outboxTimer?.cancel();
    _outboxTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      unawaited(_retryQueuedAlerts());
    });
    unawaited(_retryQueuedAlerts());
    await VoiceGuardService.flog('sosexec', 'executor loop started');
    // BG isolate rebooted mid-SOS (OS kill + restart): a native-owned flow
    // may have finished recording while we were dead. Resume the send
    // instead of stranding the evidence until the app opens.
    unawaited(_resumeInterrupted());
  }

  static Future<void> _resumeInterrupted() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      // Cross-isolate coherency: native cancel/alarm writes may have landed
      // while this isolate was dead.
      try {
        await prefs.reload().timeout(const Duration(seconds: 3));
      } catch (_) {}
      final bootState = prefs.getString(stateKey) ?? '';
      final bootCommand = (prefs.getString(commandKey) ?? '').trim();
      final bootCancelled = SosLifecycle.isCancelledSession(
        sessionId: prefs.getString(sessionIdKey),
        cancelledSessionId: prefs.getString(cancelledSessionIdKey),
        command: bootCommand,
        startedAt: prefs.getInt(startedAtKey),
        cancelledAt: prefs.getInt(cancelledAtKey),
      );
      // A cancel that landed right before the isolate died must be committed
      // before the sending/recording reconcile below can resurrect it.
      if (bootCommand == 'cancel' ||
          (bootCancelled && SosLifecycle.isActiveState(bootState))) {
        await commitCancellation(reason: 'boot reconcile');
        return;
      }
      // Sending-phase reconcile (boot during 'sending'): the in-memory loop
      // restarts idle while prefs still says sending. Never auto-send here —
      // reconcile to a safe re-check only. A delivered caseId parks as
      // listening; otherwise refresh startedAt once so the UI stale-owner
      // gate sees a recent owner instead of an instantly-stale orphan (the
      // existing stale path re-checks evidence after its own timeout).
      try {
        final sendingMarked =
            prefs.containsKey(sendingAtKey) || bootState == 'sending';
        if (sendingMarked) {
          final deliveredId = prefs.getString(caseIdKey) ?? '';
          if (deliveredId.isNotEmpty) {
            await prefs.remove(sendingAtKey);
            await prefs.setString(stateKey, 'listening');
            await prefs.setInt(remainingKey, 0);
            await VoiceGuardService.flog(
              'sosexec',
              'reconciled interrupted sending with case=$deliveredId → listening (no resend)',
            );
          } else {
            await prefs.setInt(
              startedAtKey,
              DateTime.now().millisecondsSinceEpoch,
            );
            await VoiceGuardService.flog(
              'sosexec',
              'reconciled interrupted sending → hold for re-check (no auto-send)',
            );
          }
        }
      } catch (_) {}
      if ((prefs.getString(stateKey) ?? '') != 'recording') return;
      if (!prefs.containsKey(nativeDoneKey)) return;
      if ((prefs.getString(caseIdKey) ?? '').isNotEmpty) return;
      if (_active) return;
      _active = true;
      _phase = 'recording';
      _remaining = 0;
      _source = prefs.getString(sourceKey) ?? '';
      _activeSessionId = prefs.getString(sessionIdKey) ?? '';
      final video = prefs.getString(videoPathKey) ?? '';
      final audioOnly = prefs.getBool(audioOnlyKey) ?? false;
      await VoiceGuardService.flog(
        'sosexec',
        'resuming interrupted SOS audioOnly=$audioOnly',
      );
      await _sendFromBackground(videoPath: video, audioOnly: audioOnly);
    } catch (e) {
      await VoiceGuardService.flog('sosexec', 'resume check failed: $e');
    }
  }

  /// A trigger arrived (voice word, power button, manual button, pending).
  /// Safe to call from EITHER isolate: in BG it runs directly; the main
  /// isolate should prefer [requestTrigger] (invoke when BG is alive).
  static Future<void> onTrigger(String source) async {
    if (_bgService == null) {
      return; // main isolate without BG: caller falls back
    }
    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      try {
        await prefs.reload().timeout(const Duration(seconds: 3));
      } catch (_) {}
    } catch (_) {
      return;
    }
    // A cancel that is still in flight wins any trigger race: a stale
    // pending-trigger replay must never overwrite the cancel fence.
    final pendingCommand = (prefs.getString(commandKey) ?? '').trim();
    final pendingState = prefs.getString(stateKey) ?? '';
    final pendingCancelled = SosLifecycle.isCancelledSession(
      sessionId: prefs.getString(sessionIdKey),
      cancelledSessionId: prefs.getString(cancelledSessionIdKey),
      command: pendingCommand,
      startedAt: prefs.getInt(startedAtKey),
      cancelledAt: prefs.getInt(cancelledAtKey),
    );
    if (pendingCommand == 'cancel' &&
        (pendingCancelled || SosLifecycle.isActiveState(pendingState))) {
      await prefs.setString(commandKey, '');
      await VoiceGuardService.flog(
        'sosexec',
        'trigger suppressed: cancel already in flight',
      );
      return;
    }
    if (_active) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _busyNotifiedAt > 3000) {
        _busyNotifiedAt = now;
        _broadcast(extra: {'busy': true, 'message': 'SOS already in progress'});
      }
      return;
    }
    _active = true;
    _phase = 'countdown';
    _remaining = 5;
    _countdownStartMs = DateTime.now().millisecondsSinceEpoch;
    _source = source;
    final sessionId = _newSessionId();
    _activeSessionId = sessionId;
    await prefs.setString(sessionIdKey, sessionId);
    await prefs.setString(stateKey, _phase);
    await prefs.setInt(remainingKey, _remaining);
    await prefs.setString(sourceKey, _source);
    await prefs.setInt(startedAtKey, _countdownStartMs);
    await prefs.setString(commandKey, '');
    await prefs.remove(caseIdKey);
    await prefs.remove(videoPathKey);
    await prefs.remove(audioPathKey);
    await prefs.setBool(audioOnlyKey, false);
    await prefs.setString(nativeCommandKey, '');
    await prefs.remove(nativeDoneKey);
    await prefs.remove(sendingAtKey);
    // Pending voice/power replays belong to the previous session. Clear
    // them so they cannot duplicate this fresh trigger.
    await prefs.remove(pendingVoiceTriggerKey);
    await prefs.remove(pendingPowerTriggerKey);
    // A fresh trigger re-arms the native alarm handshake.
    await prefs.setInt(alarmHandledKey, 0);
    // Native alarm (full-screen cancel UI over home/lock screen). The
    // persistent PowerGuardService polls this key and posts the FSI
    // notification — no platform channel needed from the BG isolate.
    final ts = DateTime.now().millisecondsSinceEpoch;
    await prefs.setInt(alarmRequestKey, ts);
    await VoiceGuardService.flog(
      'sosexec',
      'TRIGGER source=$source session=$sessionId',
    );
    _broadcast(extra: {'sessionId': sessionId});
  }

  /// Cancel the in-flight SOS. Safe from either isolate: the commit below is
  /// idempotent and works even when this isolate's `_active` flag was lost
  /// (BG restart / orphaned mirror), so a cancel can never be a no-op.
  static Future<void> onCancel({bool fromInvoke = false}) async {
    // `fromInvoke` is kept for call-site compatibility; both paths are the
    // same user-initiated cancellation.
    await commitCancellation(reason: 'user cancel');
  }

  /// Post-cancel voice grace: new voice fires are suppressed this long after
  /// an explicit user cancel (every _doCancel reason below is user-initiated:
  /// in-app, alarm pill, notif action, recording-phase). Manual/power
  /// triggers bypass it entirely (the grace is checked only in the voice
  /// path). Single source of truth for the banner text.
  static const int postCancelGraceSeconds = 5;
  static Duration get postCancelVoiceGrace =>
      Duration(seconds: postCancelGraceSeconds);
  static DateTime? lastUserCancelAt;

  static Future<void> _doCancel(String reason) async {
    await commitCancellation(reason: reason);
  }

  /// Centralized, idempotent, session-scoped cancellation.
  ///
  /// Returns true when the session is cancelled (or already was), false when
  /// the request targets a stale session or persistence failed. Callers must
  /// NOT report success on false.
  static Future<bool> commitCancellation({
    String reason = 'user cancel',
    String? sessionId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      try {
        await prefs.reload().timeout(const Duration(seconds: 3));
      } catch (_) {}

      var current = (prefs.getString(sessionIdKey) ?? '').trim();
      final requested = (sessionId ?? '').trim();
      if (requested.isNotEmpty && current.isEmpty) {
        // Local flow whose id was not mirrored yet: adopt the caller's id so
        // the persisted fence and the UI agree.
        current = requested;
        await prefs.setString(sessionIdKey, current);
      }
      if (requested.isNotEmpty && current.isNotEmpty && requested != current) {
        await VoiceGuardService.flog(
          'sosexec',
          'cancel ignored: stale session=$requested current=$current',
        );
        return false;
      }

      final cancelledSession = (prefs.getString(cancelledSessionIdKey) ?? '')
          .trim();
      final state = prefs.getString(stateKey) ?? '';
      final alreadyCancelled =
          current.isNotEmpty &&
          current == cancelledSession &&
          !SosLifecycle.isActiveState(state);
      final now = DateTime.now().millisecondsSinceEpoch;

      // Persist the complete cancellation BEFORE tearing down in-memory
      // ownership. If persistence fails the session stays recoverable and the
      // caller can retry instead of showing a false success.
      await prefs.setString(stateKey, 'listening');
      await prefs.setInt(remainingKey, 0);
      await prefs.setString(commandKey, '');
      await prefs.setString(nativeCommandKey, 'stop');
      // Zero (not remove) so native's `alarmTs > 0` check is false and a
      // stale `alarm_handled` can never resurrect this session.
      await prefs.setInt(alarmRequestKey, 0);
      await prefs.setInt(alarmHandledKey, 0);
      await prefs.remove(sendingAtKey);
      await prefs.remove(nativeDoneKey);
      await prefs.remove(pendingVoiceTriggerKey);
      await prefs.remove(pendingPowerTriggerKey);
      if (current.isNotEmpty) {
        await prefs.setString(cancelledSessionIdKey, current);
      }
      if (!alreadyCancelled) {
        await prefs.setInt(cancelledAtKey, now);
        await prefs.setString(cancelReasonKey, reason);
      }

      // In-memory teardown only runs after the persisted commit.
      lastUserCancelAt = DateTime.now();
      _active = false;
      _phase = 'listening';
      _remaining = 0;
      _stopTracking();
      _activeSessionId = '';
      await VoiceGuardService.flog(
        'sosexec',
        'CANCELLED ($reason) session=${current.isEmpty ? "(legacy)" : current}',
      );
      await _resumeMicBestEffort('cancelled');
      if (!alreadyCancelled) {
        _broadcast(
          extra: {
            'cancelled': true,
            'message':
                'SOS cancelled — voice trigger paused ${postCancelGraceSeconds}s',
            'sessionId': current,
          },
        );
      }
      return true;
    } catch (e) {
      await VoiceGuardService.flog('sosexec', 'cancel failed: $e');
      return false;
    }
  }

  /// 1s heartbeat: power-trigger poll, cancel-command poll, countdown ticks.
  static Future<void> _poll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Same cross-isolate coherency as readSnapshot: the power trigger is
      // stashed by the native receiver and cancels arrive from the main
      // isolate / native alarm activity. Reload so this BG-side read sees
      // their writes instead of the boot-time cache.
      try {
        await prefs.reload().timeout(const Duration(seconds: 3));
      } catch (_) {}

      // Cancel commands are consumed FIRST and even when this isolate's
      // `_active` flag is false (BG restart / orphaned mirror). This ordering
      // is the core of the fix: the check previously sat after
      // `if (!_active) return;`, so a native cancel could never commit.
      if ((prefs.getString(commandKey) ?? '').trim() == 'cancel') {
        await commitCancellation(reason: 'alarm-activity cancel');
        return;
      }

      // Power-button path: native receiver stashed a trigger while we run.
      final powerTs = prefs.getInt(pendingPowerTriggerKey);
      if (powerTs != null) {
        final age = DateTime.now().millisecondsSinceEpoch - powerTs;
        await prefs.remove(pendingPowerTriggerKey);
        final cancelledAt = prefs.getInt(cancelledAtKey) ?? 0;
        final session = (prefs.getString(sessionIdKey) ?? '').trim();
        final cancelledSession = (prefs.getString(cancelledSessionIdKey) ?? '')
            .trim();
        // A power press that predates the cancel is a replay, not a new SOS.
        // A press AFTER the cancel (powerTs > cancelledAt) is deliberate and
        // must still work.
        final replayOfCancelled =
            cancelledAt > 0 &&
            (session.isEmpty ||
                (session.isNotEmpty && session == cancelledSession)) &&
            powerTs <= cancelledAt;
        if (age >= 0 && age <= 60000 && !replayOfCancelled) {
          await VoiceGuardService.flog('sosexec', 'power trigger polled');
          await onTrigger('power-button');
          return;
        }
        if (replayOfCancelled) {
          await VoiceGuardService.flog(
            'sosexec',
            'power trigger replay ignored (cancelled session)',
          );
        }
      }

      if (!_active) return;

      // Live-owner heartbeat: renew startedAt on every tick while owned so
      // the UI stale-owner gate (which expects per-tick renewal) keeps
      // seeing a live owner. Additive only: phase/remaining/broadcast timing
      // below is untouched.
      try {
        await prefs.setInt(startedAtKey, DateTime.now().millisecondsSinceEpoch);
      } catch (_) {}

      // Single 5s cancel countdown (elapsed-driven): 5→4→3→2→1, one full
      // second per step, then activation. No second phase, so the displayed
      // number can never restart mid-flow.
      if (_phase == 'countdown') {
        final elapsed =
            DateTime.now().millisecondsSinceEpoch - _countdownStartMs;
        if (elapsed >= 5000) {
          await _beginRecording(prefs);
          return;
        }
        final rem = 5 - (elapsed ~/ 1000);
        if (rem > 0 && rem != _remaining) {
          _remaining = rem;
          await prefs.setInt(remainingKey, _remaining);
          _broadcast();
        }
        return;
      }

      if (_phase == 'recording') {
        // The 30s evidence window drives the number the UI mirror shows
        // while the background owns the recording.
        if (_remaining > 0) {
          _remaining -= 1;
          await prefs.setInt(remainingKey, _remaining);
        }
        _broadcast();
        return;
      }

      // sending/sent phases are event-driven (see below), the tick only
      // keeps the poll alive for cancel + power triggers.
      _broadcast();
    } catch (e) {
      await VoiceGuardService.flog('sosexec', 'poll error: $e');
    }
  }

  static Future<void> _beginRecording(SharedPreferences prefs) async {
    _phase = 'recording';
    _remaining = 30;
    await prefs.setString(stateKey, _phase);
    await prefs.setInt(remainingKey, _remaining);
    _broadcast();
    final fg = _isForeground?.call() ?? false;
    await VoiceGuardService.flog(
      'sosexec',
      'countdown elapsed → recording fg=$fg',
    );

    if (fg) {
      // App is open: the main isolate records with the existing
      // CameraController pipeline and reports back the file path.
      try {
        _bgService?.invoke(sosStartAppRecording);
      } catch (_) {}
      // Fallback: if the main isolate never reports back (killed between
      // the check and the invoke), go native after 45 s instead of hanging.
      unawaited(_appRecordingFallback());
      return;
    }
    await _beginNativeRecording(prefs);
  }

  static Future<void> _appRecordingFallback() async {
    await Future.delayed(const Duration(seconds: 45));
    if (!_active || _phase != 'recording') return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(videoPathKey) != null) return; // main reported in
    } catch (_) {}
    await VoiceGuardService.flog('sosexec', 'app recording no-show → native');
    try {
      final prefs = await SharedPreferences.getInstance();
      await _beginNativeRecording(prefs);
    } catch (_) {}
  }

  /// Called (via invoke) by the main isolate when its CameraController
  /// recording finishes. Continues the chain in the background.
  static Future<void> onAppRecordingDone(
    String? videoPath,
    String? error,
  ) async {
    if (!_active || _phase != 'recording') return;
    // A cancel may have landed between the report and this handler.
    try {
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getString(commandKey) ?? '') == 'cancel') {
        await _doCancel('cancel before app-recording report');
        return;
      }
    } catch (_) {}
    if (videoPath == null || videoPath.isEmpty) {
      await VoiceGuardService.flog(
        'sosexec',
        'app recording failed ($error) → native',
      );
      try {
        final prefs = await SharedPreferences.getInstance();
        await _beginNativeRecording(prefs);
      } catch (_) {}
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(videoPathKey, videoPath);
    } catch (_) {}
    await _sendFromBackground(videoPath: videoPath, audioOnly: false);
  }

  static Future<void> _beginNativeRecording(SharedPreferences prefs) async {
    // The KWS mic loop holds the microphone — release it first so the
    // native recorder (CameraX audio / MediaRecorder) can claim it.
    try {
      await onPauseMic?.call().timeout(const Duration(seconds: 10));
    } catch (e) {
      await VoiceGuardService.flog('sosexec', 'mic pause failed: $e');
    }
    await prefs.setString(nativeCommandKey, 'start_recording');
    await VoiceGuardService.flog('sosexec', 'native recording requested');
    // Wait for SosRecordingService to finish (30 s clip + margin), while
    // still honoring cancel via the normal tick.
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      if (!_active || _phase != 'recording') return; // cancelled meanwhile
      SharedPreferences p;
      try {
        p = await SharedPreferences.getInstance();
        // Native recorder + alarm activity write from outside this isolate:
        // reload each iteration so cancel/done are seen promptly.
        try {
          await p.reload().timeout(const Duration(seconds: 3));
        } catch (_) {}
      } catch (_) {
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }
      if ((p.getString(commandKey) ?? '') == 'cancel') {
        await _doCancel('cancel during native recording');
        return;
      }
      if (p.containsKey(nativeDoneKey)) {
        final video = p.getString(videoPathKey) ?? '';
        final audioOnly = p.getBool(audioOnlyKey) ?? false;
        await VoiceGuardService.flog(
          'sosexec',
          'native recording done audioOnly=$audioOnly',
        );
        await _sendFromBackground(videoPath: video, audioOnly: audioOnly);
        return;
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    await VoiceGuardService.flog(
      'sosexec',
      'native recording timeout → send anyway',
    );
    await _sendFromBackground(videoPath: '', audioOnly: true);
  }

  /// Cancel fence for an in-flight background send. True means the session
  /// was cancelled (or ownership was lost) and the caller must abort without
  /// writing `sent`, `caseId` or starting location tracking.
  static Future<bool> _sessionWasCancelled(
    SharedPreferences? prefsRef,
    String session,
  ) async {
    if (!_active) return true;
    try {
      final prefs = prefsRef ?? await SharedPreferences.getInstance();
      try {
        await prefs.reload().timeout(const Duration(seconds: 3));
      } catch (_) {}
      if ((prefs.getString(commandKey) ?? '').trim() == 'cancel') return true;
      final cancelledSession = (prefs.getString(cancelledSessionIdKey) ?? '')
          .trim();
      if (session.isNotEmpty) return cancelledSession == session;
      return SosLifecycle.isCancelledSession(
        command: prefs.getString(commandKey),
        startedAt: prefs.getInt(startedAtKey),
        cancelledAt: prefs.getInt(cancelledAtKey),
      );
    } catch (_) {
      // Never abort a genuine emergency send because prefs hiccuped.
      return false;
    }
  }

  static Future<void> _abortCancelledSend(
    SharedPreferences? prefsRef,
    String session,
  ) async {
    _active = false;
    _phase = 'listening';
    _remaining = 0;
    try {
      final prefs = prefsRef ?? await SharedPreferences.getInstance();
      await prefs.setString(stateKey, 'listening');
      await prefs.setInt(remainingKey, 0);
      await prefs.remove(sendingAtKey);
    } catch (_) {}
    await VoiceGuardService.flog(
      'sosexec',
      'send aborted — session cancelled session=${session.isEmpty ? "(legacy)" : session}',
    );
    await _resumeMicBestEffort('send-cancelled');
  }

  static Future<void> _sendFromBackground({
    required String videoPath,
    required bool audioOnly,
  }) async {
    if (!_active) return;
    SharedPreferences? prefsRef;
    var session = '';
    try {
      prefsRef = await SharedPreferences.getInstance();
      try {
        await prefsRef.reload().timeout(const Duration(seconds: 3));
      } catch (_) {}
      session = (prefsRef.getString(sessionIdKey) ?? '').trim();
    } catch (_) {}
    if (await _sessionWasCancelled(prefsRef, session)) {
      await _abortCancelledSend(prefsRef, session);
      return;
    }
    _phase = 'sending';
    try {
      final prefs = prefsRef ?? await SharedPreferences.getInstance();
      await prefs.setString(stateKey, _phase);
      await prefs.setInt(sendingAtKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
    _broadcast();

    String lat = '';
    String lng = '';
    String link = '';
    try {
      final loc = await LocationService.getCurrent(
        fresh: true,
      ).timeout(const Duration(seconds: 20));
      if (loc != null) {
        lat = loc.latitude.toString();
        lng = loc.longitude.toString();
        link = loc.googleMapsLink;
      }
    } catch (e) {
      await VoiceGuardService.flog('sosexec', 'BG location failed: $e');
    }

    if (await _sessionWasCancelled(prefsRef, session)) {
      await _abortCancelledSend(prefsRef, session);
      return;
    }

    String audioPath = '';
    try {
      // Auth rides per-request from secure storage (ApiClient interceptor
      // reads the same Android Keystore entry in this isolate). Pre-check
      // so a logged-out phone fails loudly instead of sending a 401.
      String token = '';
      try {
        token =
            await ApiClient.getToken().timeout(const Duration(seconds: 10)) ??
            '';
      } catch (e) {
        await VoiceGuardService.flog('sosexec', 'BG token read failed: $e');
      }
      if (token.isEmpty) throw StateError('not logged in (no auth token)');
      // Audio-only fallback (native recording without camera) rides the
      // audio field; the server accepts audio without video.
      try {
        final prefs = await SharedPreferences.getInstance();
        if (audioOnly) audioPath = prefs.getString(audioPathKey) ?? '';
      } catch (_) {}
      final svc = SosService();
      final caseData = await svc
          .createCase(
            videoPath: videoPath,
            audioPath: audioPath,
            locationLink: link,
            latitude: lat,
            longitude: lng,
            notes: 'SOS Alert ($_source) at ${DateTime.now().toLocal()}',
          )
          .timeout(const Duration(minutes: 3));
      // Cancel may have landed while the POST was in flight. Do not mirror
      // `sent`/caseId or start tracking for a cancelled session (the server
      // may still have created the case — documented limitation).
      if (await _sessionWasCancelled(prefsRef, session)) {
        await VoiceGuardService.flog(
          'sosexec',
          'POST completed after cancel — case=${caseData.id} not adopted',
        );
        await _abortCancelledSend(prefsRef, session);
        return;
      }
      _phase = 'sent';
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(stateKey, _phase);
        await prefs.setString(caseIdKey, caseData.id);
        await prefs.remove(sendingAtKey);
      } catch (_) {}
      await VoiceGuardService.flog('sosexec', 'SENT case=${caseData.id}');
      _broadcast(
        extra: {
          'sent': true,
          'message':
              'Emergency alert sent successfully! Help is on the way. Your live location is being tracked.',
        },
      );
      _active = false; // new triggers allowed; tracking continues by caseId
      _startTracking(caseData.id);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(stateKey, 'listening');
      } catch (_) {}
      await _resumeMicBestEffort('sent');
    } catch (e) {
      final cancelledNow = await _sessionWasCancelled(prefsRef, session);
      _active = false;
      _phase = cancelledNow ? 'listening' : 'idle';
      try {
        final prefs = prefsRef ?? await SharedPreferences.getInstance();
        await prefs.setString(stateKey, _phase);
        await prefs.remove(sendingAtKey);
      } catch (_) {}
      if (cancelledNow) {
        await VoiceGuardService.flog(
          'sosexec',
          'send aborted after cancel: $e',
        );
        await _resumeMicBestEffort('send-cancelled');
        return;
      }
      await VoiceGuardService.flog('sosexec', 'SEND FAILED: $e');
      PendingSosAlert? queued;
      try {
        queued = await SosOutbox.enqueue(
          sessionId: session,
          notes: 'SOS Alert ($_source) at ${DateTime.now().toLocal()}',
          latitude: lat,
          longitude: lng,
          locationLink: link,
          videoPath: videoPath,
          audioPath: audioPath,
          source: _source,
        );
      } catch (queueError) {
        await VoiceGuardService.flog(
          'sosexec',
          'outbox enqueue failed: $queueError',
        );
      }
      _broadcast(
        extra: {
          'failed': true,
          'queued': queued != null,
          'message': queued != null
              ? 'Could not reach ZELDA servers. Your alert and evidence were saved and will be retried automatically when you are back online.'
              : 'Failed to send emergency alert. Please check your connection and try again.',
        },
      );
      await _resumeMicBestEffort('send-failed');
    }
  }

  /// Deliver alerts that were saved while the phone had no connectivity.
  /// Runs from the always-on voice foreground service, so a failed SOS can be
  /// completed without the user reopening the app.
  static Future<void> _retryQueuedAlerts() async {
    if (_active ||
        _phase == 'sending' ||
        _phase == 'recording' ||
        _phase == 'countdown' ||
        _phase == 'cancelWindow') {
      return;
    }
    try {
      final delivered = await SosOutbox.retryPending();
      if (delivered.isEmpty) return;
      final first = delivered.first;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(caseIdKey, first.id);
      } catch (_) {}
      await VoiceGuardService.flog(
        'sosexec',
        'OUTBOX delivered ${delivered.length} case(s) first=${first.id}',
      );
      _broadcast(
        extra: {
          'sent': true,
          'message':
              'A saved emergency alert was delivered. Your live location is being tracked.',
        },
      );
      _startTracking(first.id);
    } catch (e) {
      await VoiceGuardService.flog('sosexec', 'outbox retry failed: $e');
    }
  }

  static void _startTracking(String caseId) {
    _trackingTimer?.cancel();
    _trackingCaseId = caseId;
    _trackingTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      try {
        final loc = await LocationService.getCurrent(
          fresh: true,
        ).timeout(const Duration(seconds: 20));
        if (loc == null) return;
        await SosService()
            .updateLocation(
              _trackingCaseId,
              latitude: loc.latitude.toString(),
              longitude: loc.longitude.toString(),
              locationLink: loc.googleMapsLink,
            )
            .timeout(const Duration(seconds: 30));
      } catch (_) {}
    });
  }

  static void _stopTracking() {
    _trackingTimer?.cancel();
    _trackingTimer = null;
    _trackingCaseId = '';
  }

  /// Live snapshot broadcast for the Flutter UI (observer).
  static void _broadcast({Map<String, Object?>? extra}) {
    final payload = <String, Object?>{
      'state': _phase,
      'remaining': _remaining,
      'source': _source,
      'active': _active,
      'sessionId': _activeSessionId,
    };
    if (extra != null) payload.addAll(extra);
    try {
      _bgService?.invoke(sosStateEvent, payload);
    } catch (_) {}
  }

  // ── main-isolate API ──

  /// Ask the BG executor to start an SOS. Returns true when a live BG
  /// engine accepted it; false when the caller must run the legacy local
  /// path instead (BG service not running, e.g. voice protection off).
  static Future<bool> requestTrigger(String source) async {
    try {
      final running = await VoiceGuardService.isRunning().timeout(
        const Duration(seconds: 3),
      );
      if (!running) return false;
      VoiceGuardService.serviceInvoke(sosTriggerInvoke, {'source': source});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Ask the BG executor to cancel (invoke + authoritative prefs commit).
  /// Returns false when the caller's session is stale or persistence failed;
  /// callers must surface that instead of a false success.
  static Future<bool> requestCancel({String? sessionId}) async {
    final committed = await commitCancellation(
      reason: 'user cancel',
      sessionId: sessionId,
    );
    if (!committed) return false;
    try {
      if (_bgService != null) {
        // Same isolate (BG): commit already ran, no round-trip needed.
        return true;
      }
      VoiceGuardService.serviceInvoke(sosCancelInvoke);
    } catch (_) {}
    return true;
  }

  /// Ask the native layer to post the full-screen SOS alarm
  /// (SosAlarmActivity over home/lock screen). The persistent
  /// PowerGuardService polls [alarmRequestKey] and posts it — no platform
  /// channel is available from the BG isolate, so prefs are the bridge.
  static Future<void> requestNativeAlarm() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        alarmRequestKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      await VoiceGuardService.flog('sosexec', 'native alarm requested');
    } catch (_) {}
  }

  static Future<Map<String, Object?>> readSnapshot() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      // Cross-isolate coherency: the BG executor (and native services)
      // write these keys from another isolate/process-side writer while the
      // UI reads them here every second. SharedPreferences caches per
      // isolate, so without reload() this poll would forever return the
      // values fetched at app start (stale 'idle') and fight the live
      // broadcast snapshots — the SOS UI flicker. Reload from disk first.
      try {
        await prefs.reload().timeout(const Duration(seconds: 5));
      } catch (_) {}
      final state = prefs.getString(stateKey) ?? 'idle';
      final command = prefs.getString(commandKey) ?? '';
      final sessionId = (prefs.getString(sessionIdKey) ?? '').trim();
      final cancelledSessionId = (prefs.getString(cancelledSessionIdKey) ?? '')
          .trim();
      final startedAt = prefs.getInt(startedAtKey) ?? 0;
      final cancelledAt = prefs.getInt(cancelledAtKey) ?? 0;
      final sessionCancelled =
          command.trim() == 'cancel' ||
          SosLifecycle.isCancelledSession(
            sessionId: sessionId,
            cancelledSessionId: cancelledSessionId,
            command: command,
            startedAt: startedAt,
            cancelledAt: cancelledAt,
          );
      return {
        'state': state,
        'remaining': prefs.getInt(remainingKey) ?? 0,
        'source': prefs.getString(sourceKey) ?? '',
        'caseId': prefs.getString(caseIdKey) ?? '',
        'videoPath': prefs.getString(videoPathKey) ?? '',
        'audioPath': prefs.getString(audioPathKey) ?? '',
        'audioOnly': prefs.getBool(audioOnlyKey) ?? false,
        'nativeDone': prefs.containsKey(nativeDoneKey),
        'command': command,
        'startedAt': startedAt,
        'sessionId': sessionId,
        'sessionCancelled': sessionCancelled,
        'cancelledSessionId': cancelledSessionId,
        'cancelledAt': cancelledAt,
        'cancelReason': prefs.getString(cancelReasonKey) ?? '',
      };
    } catch (_) {
      return {
        'state': 'idle',
        'remaining': 0,
        'source': '',
        'caseId': '',
        'sessionCancelled': false,
      };
    }
  }

  /// Clears a stale/orphaned BG mirror so the UI (and future triggers) are
  /// not haunted by a dead owner's frozen state. Keeps finished evidence and
  /// the delivered case id intact for adoption.
  static Future<void> resetMirror() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      await prefs.setString(stateKey, 'idle');
      await prefs.setInt(remainingKey, 0);
      await prefs.remove(commandKey);
      await prefs.remove(nativeDoneKey);
      await prefs.remove(sendingAtKey);
      await prefs.setString(nativeCommandKey, '');
      await prefs.remove(pendingVoiceTriggerKey);
      await prefs.remove(pendingPowerTriggerKey);
      await prefs.setInt(alarmRequestKey, 0);
      await prefs.setInt(alarmHandledKey, 0);
    } catch (_) {}
  }

  /// Current session id, or '' for legacy snapshots.
  static Future<String> currentSessionId() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      try {
        await prefs.reload().timeout(const Duration(seconds: 3));
      } catch (_) {}
      return (prefs.getString(sessionIdKey) ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  /// Start a main-isolate (no BG engine) session: stamps a fresh id and
  /// clears anything left over from the previous session WITHOUT writing an
  /// active state (the caller owns the local countdown).
  static Future<String> beginLocalSession() async {
    final prefs = await SharedPreferences.getInstance().timeout(
      const Duration(seconds: 5),
    );
    final id = _newSessionId();
    await prefs.setString(sessionIdKey, id);
    await prefs.setString(commandKey, '');
    await prefs.remove(pendingVoiceTriggerKey);
    await prefs.remove(pendingPowerTriggerKey);
    await prefs.remove(nativeDoneKey);
    await prefs.remove(sendingAtKey);
    await prefs.setInt(alarmHandledKey, 0);
    return id;
  }

  /// Fence check used by the UI/controller before sending anything.
  static Future<bool> isCurrentSessionCancelled() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      try {
        await prefs.reload().timeout(const Duration(seconds: 3));
      } catch (_) {}
      return SosLifecycle.isCancelledSession(
        sessionId: prefs.getString(sessionIdKey),
        cancelledSessionId: prefs.getString(cancelledSessionIdKey),
        command: prefs.getString(commandKey),
        startedAt: prefs.getInt(startedAtKey),
        cancelledAt: prefs.getInt(cancelledAtKey),
      );
    } catch (_) {
      return false;
    }
  }
}
