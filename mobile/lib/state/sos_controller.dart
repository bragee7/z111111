import 'dart:async';

import 'package:camera/camera.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sos_case.dart';
import '../services/location_service.dart';
import '../services/sos_executor.dart';
import '../services/sos_outbox.dart';
import '../services/sos_service.dart';
import '../services/voice_guard_service.dart';
import '../services/power_sos_service.dart';

enum SosStatus {
  idle,
  listening,
  cancelWindow,
  countdown,
  recording,
  sending,
  sent,
}

class SosController extends ChangeNotifier {
  final SosService _sosService = SosService();

  SosStatus _status = SosStatus.idle;
  int? _cancelTimer;
  int? _countdown;
  int _recordingTime = 30;
  String _error = '';
  String _success = '';

  AppLocation? _location;
  String _locationLink = '';

  bool _isTracking = false;

  String? _recordedVideoPath;
  String? _recordedAudioPath;
  bool _showPreview = false;

  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _cameraInitialized = false;
  CameraLensDirection _selectedLens = CameraLensDirection.back;

  Timer? _cancelTimerRef;
  Timer? _recordingTimerRef;
  Timer? _trackingRef;
  StreamSubscription<AppLocation>? _watchSub;
  StreamSubscription<String>? _detectionSub;
  StreamSubscription<bool>? _statusSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<void>? _powerSub;
  StreamSubscription<Map<String, Object?>>? _mirrorSub;
  StreamSubscription<void>? _appRecSub;
  Timer? _mirrorTimer;
  Timer? _outboxTimer;

  /// True while a BG executor owns the SOS: the UI only renders snapshots,
  /// never runs local timers (single authoritative state, no duplicates).
  bool _mirroring = false;

  /// True once this open app adopted a native-owned recording (evidence
  /// file + nativeDone in the mirror) and took over the send. Reset when
  /// the flow ends so a later SOS can adopt again. Prevents double-send
  /// from the 1s mirror timer re-firing on the same snapshot.
  bool _adoptedNative = false;
  static const _staleOwnerMs = 180000; // 3 min: longest live flow is ~60s
  bool _voiceEnabled = false;
  bool _powerSosEnabled = true;
  bool _initialized = false;

  /// True while a cancellation request is in flight: the cancel UI shows a
  /// busy state and ignores repeated taps (no duplicate cancel commands).
  bool _cancelling = false;

  SosStatus get status => _status;
  int? get cancelTimer => _cancelTimer;
  int? get countdown => _countdown;
  int get recordingTime => _recordingTime;
  String get error => _error;
  String get success => _success;
  AppLocation? get location => _location;
  String get locationLink => _locationLink;
  bool get isTracking => _isTracking;
  String? get recordedVideoPath => _recordedVideoPath;
  String? get recordedAudioPath => _recordedAudioPath;
  bool get showPreview => _showPreview;
  CameraController? get cameraController => _cameraController;
  bool get cameraInitialized => _cameraInitialized;
  CameraLensDirection get selectedLens => _selectedLens;
  bool get voiceEnabled => _voiceEnabled;
  bool get powerSosEnabled => _powerSosEnabled;

  bool get isBusy =>
      _status != SosStatus.idle && _status != SosStatus.listening;

  /// True while a cancellation request is in flight (drives the busy state of
  /// the shared CancelSosButton; prevents duplicate cancellation requests).
  bool get isCancelling => _cancelling;

  /// Last session this UI confirmed as cancelled. Snapshots for this id are
  /// forced to the idle surface even if a late callback/native tick tries to
  /// restore an active state.
  String _cancelledSessionId = '';

  /// Releases every mirror/local-flow handle. Called only after a confirmed
  /// cancellation (or when the authoritative snapshot says the session is
  /// cancelled) so no timer can re-show the cancel surface.
  void _releaseMirror() {
    _mirroring = false;
    _adoptedNative = false;
    _cancelTimerRef?.cancel();
    _cancelTimerRef = null;
    _recordingTimerRef?.cancel();
    _recordingTimerRef = null;
    _cancelTimer = null;
    _countdown = null;
  }

  /// Starts the single 5s cancel countdown (also used to re-arm after a
  /// failed cancellation). Guards every tick against a concurrent cancel so a
  /// cancelled session can never transition into recording.
  void _armCancelCountdown(int from) {
    _cancelTimerRef?.cancel();
    _cancelTimer = from;
    _cancelTimerRef = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_cancelling || _status != SosStatus.countdown) {
        timer.cancel();
        if (identical(_cancelTimerRef, timer)) _cancelTimerRef = null;
        return;
      }
      _cancelTimer = (_cancelTimer ?? from) - 1;
      if (_cancelTimer! <= 0) {
        timer.cancel();
        _cancelTimerRef = null;
        _cancelTimer = null;
        startRecording();
      }
      notifyListeners();
    });
  }

  /// Test seam: exercises the real snapshot reconciliation without booting
  /// plugins (geolocator/camera/voice) in a widget test.
  @visibleForTesting
  void debugApplySnapshot(Map<String, Object?> snap) => _applySnapshot(snap);

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    _watchSub = LocationService.watchPosition().listen((loc) {
      _location = loc;
      _locationLink = loc.googleMapsLink;
      notifyListeners();
    });

    _detectionSub = VoiceGuardService.detections.listen((keyword) {
      // Route every detection through triggerSOS — it shows
      // "SOS already in progress" when busy instead of dropping silently.
      triggerSOS(triggerKeyword: keyword);
    });

    _statusSub = VoiceGuardService.statusStream.listen((running) {
      if (_voiceEnabled != running) {
        _voiceEnabled = running;
        notifyListeners();
      }
    });

    _errorSub = VoiceGuardService.errors.listen((error) {
      _error = error;
      _voiceEnabled = false;
      notifyListeners();
    });

    try {
      _cameras = await availableCameras();
    } catch (_) {
      _cameras = [];
    }

    _voiceEnabled = await VoiceGuardService.isRunning();
    // 3x power-press: same triggerSOS path => same 5s cancel window.
    _powerSub = PowerSosService.detections.listen((_) {
      // Same triggerSOS path (with busy feedback) as voice detections.
      triggerSOS(triggerKeyword: 'power-button');
    });
    _powerSosEnabled = await PowerSosService.isEnabled();
    await PowerSosService.initialize();

    // BG executor observer: live snapshots (BG authority) + app-recording
    // requests (open app records with CameraController for the executor).
    _mirrorSub = VoiceGuardService.sosStateStream.listen(
      (snap) => _applySnapshot(snap),
    );
    _appRecSub = VoiceGuardService.appRecordingRequests.listen(
      (_) => recordForExecutor(),
    );
    _mirrorTimer?.cancel();
    _mirrorTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _syncFromExecutor(),
    );
    // Opening the app mid-SOS must show the LIVE state, never restart it.
    await _syncFromExecutor();
    _outboxTimer?.cancel();
    _outboxTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _retryOutbox(),
    );
    unawaited(_retryOutbox());
    notifyListeners();
  }

  /// One-way sync from the BG executor mirror. Never starts timers, never
  /// creates an SOS — purely renders the authoritative background state.
  Future<void> _syncFromExecutor() async {
    try {
      final snap = await SosExecutor.readSnapshot();
      final raw = (snap['state'] as String?) ?? 'idle';
      final snapSession = (snap['sessionId'] as String?) ?? '';
      final snapCancelled =
          snap['sessionCancelled'] == true ||
          (snapSession.isNotEmpty && snapSession == _cancelledSessionId);
      // A cancelled session is never "stale evidence": reconcile it to the
      // idle surface before the stale-owner gate can adopt/send anything.
      if (snapCancelled) {
        _applySnapshot(snap);
        return;
      }
      if (raw != 'idle' && raw != 'listening') {
        // Stale-owner gate: the longest real flow is ~60s (5s countdown +
        // 30s record + send), and the native driver renews
        // started_at on every tick. An active snapshot older than the
        // threshold is therefore orphaned — even when the BG service
        // process happens to be alive, no live owner drives it. Applying
        // it every second would bury local progress and freeze the UI
        // (e.g. stuck RECORDING 21). Recover instead.
        final startedAt = (snap['startedAt'] as int?) ?? 0;
        final age = DateTime.now().millisecondsSinceEpoch - startedAt;
        if (startedAt <= 0 || age > _staleOwnerMs) {
          await _recoverStaleMirror(snap);
          return;
        }
      }
      _applySnapshot(snap);
    } catch (_) {}
  }

  /// Recovers from a dead BG owner's frozen mirror. Adopts finished evidence
  /// and sends it once; otherwise clears the stale mirror and unfreezes the
  /// UI without touching live local timers (they own the flow now).
  Future<void> _recoverStaleMirror(Map<String, Object?> snap) async {
    if (snap['sessionCancelled'] == true) {
      final snapSession = (snap['sessionId'] as String?) ?? '';
      if (snapSession.isNotEmpty) _cancelledSessionId = snapSession;
      _releaseMirror();
      _status = SosStatus.listening;
      await SosExecutor.resetMirror();
      notifyListeners();
      return;
    }
    if (_status == SosStatus.sending || _status == SosStatus.sent) return;
    final video = (snap['videoPath'] as String?) ?? '';
    final audio = (snap['audioPath'] as String?) ?? '';
    if ((video.isNotEmpty || audio.isNotEmpty) && !_adoptedNative) {
      _adoptedNative = true;
      _mirroring = false;
      _recordedVideoPath = video.isNotEmpty ? video : null;
      _recordedAudioPath = audio;
      await sendEmergencyData();
      return;
    }
    await SosExecutor.resetMirror();
    _mirroring = false;
    _adoptedNative = false;
    if (_recordingTimerRef == null &&
        _cancelTimerRef == null &&
        _status != SosStatus.sending &&
        _status != SosStatus.sent) {
      _status = SosStatus.listening;
    }
    notifyListeners();
  }

  void _applySnapshot(Map<String, Object?> snap) {
    final raw = (snap['state'] as String?) ?? 'idle';
    final mapped = _mapExecutorState(raw);
    final remaining = (snap['remaining'] as int?) ?? 0;
    final snapSession = (snap['sessionId'] as String?) ?? '';

    // Cancellation fence: a snapshot for a cancelled session can never map
    // back to an active surface — no matter which callback/timer delivered it.
    // `sessionCancelled` also covers an in-flight native cancel command.
    if (snap['sessionCancelled'] == true ||
        snap['cancelled'] == true ||
        (snapSession.isNotEmpty && snapSession == _cancelledSessionId)) {
      if (snapSession.isNotEmpty) _cancelledSessionId = snapSession;
      final wasActive =
          _mirroring ||
          _status == SosStatus.cancelWindow ||
          _status == SosStatus.countdown ||
          _status == SosStatus.recording ||
          _status == SosStatus.sending;
      _releaseMirror();
      _status = SosStatus.listening;
      _error = '';
      if (snap['cancelled'] == true) {
        _success = (snap['message'] as String?) ?? 'SOS alert cancelled';
        VoiceGuardService.resetDetectionCooldown();
        notifyListeners();
        Future.delayed(const Duration(seconds: 3), () {
          _success = '';
          notifyListeners();
        });
        return;
      }
      if (wasActive) notifyListeners();
      return;
    }

    if (raw == 'idle' || raw == 'listening') {
      if (_mirroring) {
        // Executor finished/cancelled: release the mirror, show its message.
        _mirroring = false;
        _adoptedNative = false;
        _cancelTimerRef?.cancel();
        _cancelTimerRef = null;
        _status = mapped;
        _cancelTimer = null;
        _countdown = null;
      } else {
        return; // nothing active anywhere — leave local UI alone
      }
    } else {
      // Authoritative BG state: take it over, kill any local timers so the
      // countdown can never run twice (which would double-record/double-send).
      _mirroring = true;
      _cancelTimerRef?.cancel();
      _cancelTimerRef = null;
      _status = mapped;
      if (mapped == SosStatus.cancelWindow) {
        _cancelTimer = remaining;
        _countdown = null;
      } else if (mapped == SosStatus.countdown) {
        _countdown = remaining;
        _cancelTimer = null;
      } else if (mapped == SosStatus.recording) {
        // A live local recording timer owns the countdown display. The BG
        // mirror stays frozen while app-recording assists (or while its owner
        // is dead) and must not stick the number every second.
        if (_recordingTimerRef == null) {
          _recordingTime = remaining;
        }
        // Native-owned flow finished recording while the app was closed
        // (evidence path + nativeDone in the mirror): adopt the file and
        // complete the send exactly once through the existing pipeline.
        // Skipped when the BG executor is alive — it owns the send then.
        if ((snap['nativeDone'] == true) && !_adoptedNative) {
          _adoptedNative = true;
          unawaited(_adoptNativeDone(snap));
        }
      }
    }

    if (snap['busy'] == true) {
      _success = (snap['message'] as String?) ?? 'SOS already in progress';
      notifyListeners();
      Future.delayed(const Duration(seconds: 3), () {
        if (_success == 'SOS already in progress') {
          _success = '';
          notifyListeners();
        }
      });
      return;
    }
    if (snap['cancelled'] == true) {
      _success = (snap['message'] as String?) ?? 'SOS alert cancelled';
      VoiceGuardService.resetDetectionCooldown();
      notifyListeners();
      Future.delayed(const Duration(seconds: 3), () {
        _success = '';
        notifyListeners();
      });
      return;
    }
    if (snap['sent'] == true) {
      _success =
          (snap['message'] as String?) ??
          'Emergency alert sent successfully! Help is on the way. Your live location is being tracked.';
      _showPreview = false;
      VoiceGuardService.resetDetectionCooldown();
      notifyListeners();
      return;
    }
    if (snap['failed'] == true) {
      _error =
          (snap['message'] as String?) ??
          'Failed to send emergency alert. Please check your connection and try again.';
      VoiceGuardService.resetDetectionCooldown();
      notifyListeners();
      return;
    }
    notifyListeners();
  }

  /// Adopt a native-owned recording (app was closed when evidence finished):
  /// take the file path(s) from the mirror and run the existing send
  /// pipeline exactly once. Yields to a live BG executor (it owns the send
  /// then) and to an already-running local send.
  Future<void> _adoptNativeDone(Map<String, Object?> snap) async {
    try {
      if (await VoiceGuardService.isRunning()) {
        _adoptedNative = false; // BG executor alive: it sends, we mirror.
        return;
      }
    } catch (_) {}
    if (_status == SosStatus.sending || _status == SosStatus.sent) {
      _adoptedNative = false;
      return;
    }
    final video = (snap['videoPath'] as String?) ?? '';
    final audio = (snap['audioPath'] as String?) ?? '';
    if (video.isEmpty && audio.isEmpty) {
      _adoptedNative = false;
      return;
    }
    _recordedVideoPath = video.isNotEmpty ? video : null;
    _recordedAudioPath = audio;
    await sendEmergencyData();
  }

  SosStatus _mapExecutorState(String raw) {
    switch (raw) {
      case 'cancelWindow':
        return SosStatus.cancelWindow;
      case 'countdown':
        return SosStatus.countdown;
      case 'recording':
        return SosStatus.recording;
      case 'sending':
        return SosStatus.sending;
      case 'sent':
        return SosStatus.sent;
      case 'listening':
        return SosStatus.listening;
      case 'idle':
      default:
        return SosStatus.idle;
    }
  }

  Future<void> setVoiceEnabled(bool enabled) async {
    _voiceEnabled = enabled;
    notifyListeners();
    if (enabled) {
      try {
        await VoiceGuardService.setEnabledPref(true);
        await VoiceGuardService.start();
      } catch (e) {
        _voiceEnabled = false;
        _error = 'Failed to start voice protection: $e';
        notifyListeners();
      }
    } else {
      await VoiceGuardService.stop();
    }
  }

  Future<void> setPowerSosEnabled(bool enabled) async {
    _powerSosEnabled = enabled;
    notifyListeners();
    await PowerSosService.setEnabled(enabled);
  }

  void playAlertSound() {
    SystemSound.play(SystemSoundType.alert);
  }

  void setCameraLens(CameraLensDirection lens) {
    if (lens == _selectedLens) return;
    _selectedLens = lens;
    notifyListeners();
  }

  Future<void> triggerSOS({String? triggerKeyword}) async {
    // A cancellation in flight owns the lifecycle: no new countdown may start
    // from a late trigger callback until it settles.
    if (_cancelling) return;
    // BG executor first: when a BG engine is alive it owns the SOS (same
    // 5s window, works app-closed). The live snapshot renders the UI.
    // Only when NO bg engine runs (voice protection off) does the legacy
    // local path below run — manual SOS behavior is unchanged in that case.
    try {
      if (await SosExecutor.requestTrigger(triggerKeyword ?? 'manual')) {
        return;
      }
    } catch (_) {}
    if (isBusy) {
      // A trigger (voice / power button / SOS button) arrived while an SOS
      // is already in flight (cancel window, countdown, recording, sending).
      // Tell the user instead of silently ignoring it — silent ignores are
      // perceived as "voice recognition broken" on the second utterance.
      _success = 'SOS already in progress';
      notifyListeners();
      Future.delayed(const Duration(seconds: 3), () {
        if (_success == 'SOS already in progress') {
          _success = '';
          notifyListeners();
        }
      });
      return;
    }

    // Local (no-BG) flow still gets a unique session id + clean leftover
    // state so its cancel fence is exact and pending replays cannot fire.
    try {
      await SosExecutor.beginLocalSession();
      if (_cancelling) return;
    } catch (_) {}

    playAlertSound();
    _error = '';
    _success = '';
    _status = SosStatus.countdown;
    notifyListeners();

    // Single 5s cancel countdown (5→4→3→2→1) straight into recording — one
    // timer, no second phase, nothing that could restart it.
    _armCancelCountdown(5);
  }

  Future<void> cancelSOS() async {
    // Single-flight: a second tap while the first cancellation request is in
    // flight is ignored (the button is also disabled/busy, this is the
    // authoritative guard).
    if (_cancelling) return;
    _cancelling = true;
    notifyListeners();
    String sessionId = '';
    try {
      // Bind the cancellation to the exact session the user is looking at.
      try {
        sessionId = await SosExecutor.currentSessionId().timeout(
          const Duration(seconds: 5),
        );
      } catch (_) {}

      // One centralized, idempotent, session-scoped commit. It clears the
      // persisted mirror, pending triggers, alarm handshake and native
      // recording command, and tears down the BG executor's timers/tracking.
      var committed = false;
      try {
        // requestCancel performs the same idempotent commit AND wakes the BG
        // isolate's in-memory teardown (onCancel → commitCancellation). Without
        // the invoke, a live BG executor keeps its own _active flag and keeps
        // broadcasting the old recording state after the prefs were cleared.
        committed = await SosExecutor.requestCancel(
          sessionId: sessionId.isEmpty ? null : sessionId,
        ).timeout(const Duration(seconds: 8));
      } catch (_) {
        committed = false;
      }
      if (!committed && sessionId.isNotEmpty) {
        // A concurrent path (native alarm activity / BG poll) may have won
        // the race. Accept only a persisted fence for THIS session with an
        // inactive state — never a guess.
        final snap = await SosExecutor.readSnapshot();
        final cancelledId = (snap['cancelledSessionId'] as String?) ?? '';
        final snapState = (snap['state'] as String?) ?? '';
        if (cancelledId == sessionId &&
            snapState != 'countdown' &&
            snapState != 'recording' &&
            snapState != 'sending') {
          committed = true;
        }
      }
      if (!committed) {
        throw StateError('cancellation was not confirmed');
      }

      // Only now is it safe to tear the UI/processes down. The camera stop
      // below aborts any in-app recording; do NOT send an app-recording error
      // report here — with the BG still alive it would fall through to
      // _beginNativeRecording and restart the recorder after the cancel.
      if (_status == SosStatus.recording && _cameraController != null) {
        try {
          if (_cameraController!.value.isRecordingVideo) {
            await _cameraController!.stopVideoRecording();
          }
        } catch (_) {}
        try {
          await _cameraController?.dispose();
        } catch (_) {}
        _cameraController = null;
        _cameraInitialized = false;
      }
      stopLocationTracking();
      _cancelledSessionId = sessionId;
      _releaseMirror();
      _status = SosStatus.listening;
      _error = '';
      _success =
          'SOS cancelled — voice trigger paused ${SosExecutor.postCancelGraceSeconds}s';
      VoiceGuardService.resetDetectionCooldown();
      Future.delayed(const Duration(seconds: 3), () {
        _success = '';
        notifyListeners();
      });
    } catch (_) {
      // Honest failure: the cancellation workflow did not confirm, so the SOS
      // state is left untouched (countdown / recording keeps running) and a
      // retryable error is surfaced instead of a fake success.
      _error = 'Failed to cancel the SOS. Please try again.';
      // The local countdown may have been consumed while we awaited; re-arm
      // it so the user still has a live cancel window to retry.
      if (_status == SosStatus.countdown) {
        _armCancelCountdown((_cancelTimer ?? 1).clamp(1, 5));
      }
    } finally {
      _cancelling = false;
      notifyListeners();
    }
  }

  /// Record the 30s evidence clip ON BEHALF of the BG executor (app is open
  /// at countdown end). Mirrors startRecording's camera handling but does
  /// NOT send: the clip path is reported back and the BG chain continues
  /// (GPS → submit → upload → tracking) without duplicating anything.
  Future<void> recordForExecutor() async {
    if (_cancelling) return;
    _status = SosStatus.recording;
    _recordingTime = 30;
    notifyListeners();
    String? videoPath;
    String? failure;
    try {
      if (_cameras.isEmpty) {
        _cameras = await availableCameras();
      }
      if (_cameras.isEmpty) {
        failure = 'No camera available on this device';
      } else {
        final camera = _cameras.firstWhere(
          (c) => c.lensDirection == _selectedLens,
          orElse: () => _cameras.first,
        );
        await _cameraController?.dispose();
        _cameraController = CameraController(
          camera,
          ResolutionPreset.medium,
          enableAudio: true,
        );
        await _cameraController!.initialize();
        _cameraInitialized = true;
        notifyListeners();
        await _cameraController!.startVideoRecording();
        final start = DateTime.now();
        _recordingTimerRef?.cancel();
        _recordingTimerRef = Timer.periodic(const Duration(milliseconds: 250), (
          timer,
        ) {
          final elapsed = DateTime.now().difference(start).inMilliseconds;
          final remaining = ((30000 - elapsed) / 1000).ceil();
          _recordingTime = remaining > 0 ? remaining : 0;
          if (elapsed >= 30000) timer.cancel();
          notifyListeners();
        });
        await Future.delayed(const Duration(seconds: 30));
        _recordingTimerRef?.cancel();
        _recordingTimerRef = null;
        try {
          if (_cameraController != null &&
              _cameraController!.value.isRecordingVideo) {
            videoPath = (await _cameraController!.stopVideoRecording()).path;
          }
        } catch (e) {
          failure = '$e';
        }
      }
    } catch (e) {
      failure = '$e';
    }
    try {
      await _cameraController?.dispose();
    } catch (_) {}
    _cameraController = null;
    _cameraInitialized = false;
    _recordedVideoPath = videoPath;
    _showPreview = false; // the BG chain owns the send; no local preview
    // A cancel may have landed while the 30s clip was recording. Keep the
    // evidence file but never report/send it for the cancelled session.
    if (_cancelling || await SosExecutor.isCurrentSessionCancelled()) {
      _status = SosStatus.listening;
      notifyListeners();
      return;
    }
    try {
      VoiceGuardService.serviceInvoke(SosExecutor.sosAppRecordingDone, {
        'videoPath': videoPath ?? '',
        'error': failure ?? '',
      });
    } catch (_) {}
    // Fallback ownership: if the BG executor is dead, nobody acts on the
    // done report — complete the send locally (or surface the error) instead
    // of freezing on the recording screen forever.
    var bgAlive = false;
    try {
      bgAlive = await VoiceGuardService.isRunning();
    } catch (_) {}
    if (!bgAlive) {
      if (videoPath != null && videoPath.isNotEmpty) {
        await sendEmergencyData();
      } else {
        _status = SosStatus.listening;
        _error = failure ?? 'Recording failed. Please try again.';
        notifyListeners();
      }
    }
    notifyListeners();
  }

  Future<void> startRecording() async {
    if (_cancelling || _status == SosStatus.listening) return;
    _status = SosStatus.recording;
    _recordingTime = 30;
    notifyListeners();

    try {
      if (_cameras.isEmpty) {
        _cameras = await availableCameras();
      }
      if (_cameras.isEmpty) {
        _error = 'No camera available on this device';
        _status = SosStatus.idle;
        notifyListeners();
        return;
      }

      final camera = _cameras.firstWhere(
        (c) => c.lensDirection == _selectedLens,
        orElse: () => _cameras.first,
      );

      _cameraController?.dispose();
      _cameraController = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: true,
      );
      await _cameraController!.initialize();
      _cameraInitialized = true;
      notifyListeners();

      await _cameraController!.startVideoRecording();

      final start = DateTime.now();
      _recordingTimerRef?.cancel();
      _recordingTimerRef = Timer.periodic(const Duration(milliseconds: 250), (
        timer,
      ) {
        if (_cancelling || _status != SosStatus.recording) {
          timer.cancel();
          return;
        }
        final elapsed = DateTime.now().difference(start).inMilliseconds;
        final remaining = ((30000 - elapsed) / 1000).ceil();
        _recordingTime = remaining > 0 ? remaining : 0;
        if (elapsed >= 30000) {
          timer.cancel();
          stopRecordingAndSend();
        }
        notifyListeners();
      });
    } catch (e) {
      _error = 'Unable to access camera/microphone. Please grant permissions.';
      _status = SosStatus.idle;
      notifyListeners();
    }
  }

  Future<void> stopRecordingAndSend() async {
    if (_cancelling) return;
    _recordingTimerRef?.cancel();
    _recordingTimerRef = null;

    XFile? videoFile;
    try {
      if (_cameraController != null &&
          _cameraController!.value.isRecordingVideo) {
        videoFile = await _cameraController!.stopVideoRecording();
      }
    } catch (_) {}

    await _cameraController?.dispose();
    _cameraController = null;
    _cameraInitialized = false;

    _recordedVideoPath = videoFile?.path;
    _recordedAudioPath = '';

    if (_cancelling || await SosExecutor.isCurrentSessionCancelled()) {
      _status = SosStatus.listening;
      notifyListeners();
      return;
    }
    await sendEmergencyData();
  }

  /// Deliver alerts that were saved when the backend was unreachable.
  /// The background executor runs the same outbox, so this is only a
  /// foreground accelerator; the outbox lock prevents a double POST.
  Future<void> _retryOutbox() async {
    if (_status != SosStatus.idle && _status != SosStatus.listening) return;
    try {
      final delivered = await SosOutbox.retryPending();
      if (delivered.isEmpty) return;
      if (_status != SosStatus.idle && _status != SosStatus.listening) return;
      final first = delivered.first;
      _error = '';
      _success =
          'A saved emergency alert was delivered. Your live location is being tracked.';
      _status = SosStatus.sent;
      notifyListeners();
      await startLocationTracking(first.id);
      Future.delayed(const Duration(seconds: 5), () {
        if (_status == SosStatus.sent) {
          _status = SosStatus.listening;
          _success = '';
          notifyListeners();
        }
      });
    } catch (_) {}
  }

  Future<void> sendEmergencyData() async {
    String sessionId = '';
    try {
      sessionId = await SosExecutor.currentSessionId();
    } catch (_) {}
    if (_cancelling || await _sendSessionCancelled(sessionId)) {
      _status = SosStatus.listening;
      notifyListeners();
      return;
    }
    _status = SosStatus.sending;
    _error = '';
    notifyListeners();

    try {
      final freshLocation = await LocationService.getCurrent(fresh: true);
      if (freshLocation != null) {
        _location = freshLocation;
        _locationLink = freshLocation.googleMapsLink;
      }
      if (await _sendSessionCancelled(sessionId)) {
        _abortLocalSend();
        return;
      }

      final videoPath = _recordedVideoPath ?? '';
      final audioPath = _recordedAudioPath ?? '';
      final locationLink = _locationLink;
      final latitude = _location?.latitude.toString() ?? '';
      final longitude = _location?.longitude.toString() ?? '';
      // Scope for the connection-drop re-check below: only a case created
      // by THIS attempt may be adopted (a different concurrent case must not
      // match). Captured before the first create; happy-path untouched
      // because _verifyCaseDelivered only runs after a connection drop.
      final attemptStartedAt = DateTime.now().toUtc();

      SosCase? caseData;
      try {
        if (await _sendSessionCancelled(sessionId)) {
          _abortLocalSend();
          return;
        }
        caseData = await _sosService.createCase(
          videoPath: videoPath,
          audioPath: audioPath,
          locationLink: locationLink,
          latitude: latitude,
          longitude: longitude,
          notes: 'SOS Alert at ${DateTime.now().toLocal()}',
        );
      } on DioException catch (e) {
        final isConnectionDrop =
            e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.unknown ||
            e.type == DioExceptionType.receiveTimeout ||
            e.error.toString().contains('Connection reset by peer') ||
            e.error.toString().contains('SocketException') ||
            e.error.toString().contains('Connection closed');

        if (isConnectionDrop) {
          caseData ??= await _verifyCaseDelivered(since: attemptStartedAt);
          caseData ??= await _sosService.createCase(
            videoPath: videoPath,
            audioPath: audioPath,
            locationLink: locationLink,
            latitude: latitude,
            longitude: longitude,
            notes: 'SOS Alert at ${DateTime.now().toLocal()}',
          );
        } else {
          rethrow;
        }
      }

      // Cancelled while the POST was in flight: never surface a delivered
      // case or start tracking for this session.
      if (await _sendSessionCancelled(sessionId)) {
        _abortLocalSend();
        return;
      }

      playAlertSound();
      _status = SosStatus.sent;
      _showPreview = videoPath.isNotEmpty;
      _success =
          'Emergency alert sent successfully! Help is on the way. Your live location is being tracked.';
      notifyListeners();

      // Mirror the delivered case id (BG send does the same) so the
      // executor's _resumeInterrupted caseId guard cannot be bypassed by a
      // local send. Silent prefs write only: states/broadcasts unchanged.
      try {
        final deliveredId = caseData.id;
        if (deliveredId.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance().timeout(
            const Duration(seconds: 5),
          );
          await prefs.setString(SosExecutor.caseIdKey, deliveredId);
        }
      } catch (_) {}

      startLocationTracking(caseData.id);

      VoiceGuardService.resetDetectionCooldown();

      Future.delayed(const Duration(seconds: 5), () {
        if (_status == SosStatus.sent) {
          _status = SosStatus.listening;
          _success = '';
          notifyListeners();
        }
      });
    } catch (e) {
      if (await _sendSessionCancelled(sessionId)) {
        _abortLocalSend();
        return;
      }
      _error =
          'Failed to send emergency alert. Please check your connection and try again.';
      try {
        final queued = await SosOutbox.enqueue(
          sessionId: sessionId,
          notes: 'SOS Alert at ${DateTime.now().toLocal()}',
          latitude: _location?.latitude.toString() ?? '',
          longitude: _location?.longitude.toString() ?? '',
          locationLink: _locationLink,
          videoPath: _recordedVideoPath ?? '',
          audioPath: _recordedAudioPath ?? '',
          source: 'app',
        );
        if (queued != null) {
          _error =
              'Could not reach ZELDA servers. Your alert and evidence were saved and will be retried automatically when you are back online.';
        }
      } catch (_) {}
      _status = SosStatus.idle;
      VoiceGuardService.resetDetectionCooldown();
      notifyListeners();
    }
  }

  /// True when the given local send session no longer owns the flow: either a
  /// cancel is in flight, the persisted fence names it, or a new session has
  /// already replaced it.
  Future<bool> _sendSessionCancelled(String sessionId) async {
    if (_cancelling) return true;
    try {
      if (sessionId.isNotEmpty) {
        final current = await SosExecutor.currentSessionId();
        if (current.isNotEmpty && current != sessionId) return true;
      }
      return await SosExecutor.isCurrentSessionCancelled();
    } catch (_) {
      return false;
    }
  }

  void _abortLocalSend() {
    _status = SosStatus.listening;
    _showPreview = false;
    notifyListeners();
  }

  Future<SosCase?> _verifyCaseDelivered({DateTime? since}) async {
    try {
      final cases = await _sosService.getCases();
      if (cases.isEmpty) return null;
      final newest = cases.first;
      final createdAt = newest.createdAt ?? newest.timestamp;
      if (createdAt == null) return null;
      final createdUtc = createdAt.toUtc();
      final nowUtc = DateTime.now().toUtc();
      final age = nowUtc.difference(createdUtc);
      // Reject future-dated (clock skew) and older-than-60s cases as before.
      if (age.inSeconds < -30 || age.inSeconds > 60) return null;
      // Scope to the case just created: a newest case that predates this
      // send attempt is a DIFFERENT concurrent case and must not be
      // adopted. 15s tolerance covers client/server clock skew.
      if (since != null &&
          createdUtc.isBefore(
            since.toUtc().subtract(const Duration(seconds: 15)),
          )) {
        return null;
      }
      return newest;
    } catch (_) {
      return null;
    }
  }

  Future<void> startLocationTracking(String caseId) async {
    _isTracking = true;
    notifyListeners();

    Future<void> sendUpdate() async {
      final loc = await LocationService.getCurrent(fresh: true);
      if (loc == null) return;
      _location = loc;
      _locationLink = loc.googleMapsLink;
      notifyListeners();
      try {
        await _sosService.updateLocation(
          caseId,
          latitude: loc.latitude.toString(),
          longitude: loc.longitude.toString(),
          locationLink: loc.googleMapsLink,
        );
      } catch (_) {}
    }

    await sendUpdate();
    _trackingRef?.cancel();
    _trackingRef = Timer.periodic(
      const Duration(seconds: 30),
      (_) => sendUpdate(),
    );
  }

  void stopLocationTracking() {
    _trackingRef?.cancel();
    _trackingRef = null;
    _isTracking = false;
    notifyListeners();
  }

  void dismissError() {
    _error = '';
    notifyListeners();
  }

  void dismissSuccess() {
    _success = '';
    notifyListeners();
  }

  void dismissPreview() {
    _showPreview = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelTimerRef?.cancel();
    _recordingTimerRef?.cancel();
    _trackingRef?.cancel();
    _mirrorTimer?.cancel();
    _outboxTimer?.cancel();
    _watchSub?.cancel();
    _detectionSub?.cancel();
    _powerSub?.cancel();
    _statusSub?.cancel();
    _errorSub?.cancel();
    _mirrorSub?.cancel();
    _appRecSub?.cancel();
    _cameraController?.dispose();
    super.dispose();
  }
}
