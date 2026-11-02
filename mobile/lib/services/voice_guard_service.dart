import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'keyword_model_manager.dart';

import 'sos_executor.dart';

class VoiceGuardService {
  static const _detectionEvent = 'keyword_detected';
  static const _statusEvent = 'service_status';
  static const _errorEvent = 'service_error';

  static const notificationChannelId = 'zelda_voice_protection';
  static const notificationChannelName = 'ZELDA Voice Protection';
  static const notificationChannelDescription =
      '24/7 background listening for the emergency trigger word';
  static const fgsNotificationId = 256;
  static const alarmNotificationId = 257;

  /// Periodic proactive KWS session rebuild while listening. Bounds the
  /// silent-deafness stall observed on this ROM (≈30 min uptime: healthy mic
  /// stream with real energy, yet the spotter stops confirming keywords —
  /// only an app relaunch restored it). Each rebuild has a ≈1–2 s deaf
  /// window; executor-owned mic time (native SOS recording) defers it.
  /// Periodic proactive KWS session rebuild while listening. Longer than the
  /// original 5 min: the 1-2 s deaf window on every rebuild is the main
  /// source of "missed" triggers, so rebuild less often. 8 min still bounds
  /// the 30-min silent-deafness stall observed on this ROM.
  static const _kwsRefreshPeriod = Duration(minutes: 8);

  /// Default trigger word. The user can add their own words from the
  /// dashboard — they are persisted and the listener rebuilds for them.
  static const List<String> defaultTriggerWords = ['Help me'];

  /// The trigger words that fire an SOS. Display-cased for the UI; the
  /// background engine uppercases them into BPE tokens for the spotter.
  static List<String> keywords = ['Help me'];

  /// Replace the trigger phrases with a new list (empty lists are rejected).
  static void setKeywords(List<String> list) {
    final cleaned =
        list.map((k) => k.trim()).where((k) => k.isNotEmpty).toList();
    if (cleaned.isEmpty) return;
    keywords = cleaned;
  }

  static final FlutterBackgroundService _service = FlutterBackgroundService();
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static final _detectionController = StreamController<String>.broadcast();
  static final _statusController = StreamController<bool>.broadcast();
  // Sticky copy of the last ENGINE-UP state. Broadcast controllers drop
  // events with zero listeners, so a running:true fired before anyone
  // subscribed (fast cached-model boot, activity recreation) would be lost
  // forever — the watchdog seeds from this and re-queries the live engine.
  static bool _lastRunning = false;
  static final _errorController = StreamController<String>.broadcast();
  static final _sosStateController =
      StreamController<Map<String, Object?>>.broadcast();
  static final _appRecordingController = StreamController<void>.broadcast();

  /// Fire-and-forget invoke on the BG isolate (no-op when it is not
  /// running — callers that need certainty check isRunning() first).
  static void serviceInvoke(String event, [Map<String, dynamic>? args]) {
    try {
      _service.invoke(event, args);
    } catch (_) {}
  }

  static bool _notificationsReady = false;

  /// Ensure the local notifications plugin is initialized in the CURRENT
  /// isolate (statics are per-isolate, so the background isolate needs its own
  /// init before it can post notifications).
  static Future<void> _ensureNotificationsInitialized() async {
    if (_notificationsReady) return;
    await _notifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            notificationChannelId,
            notificationChannelName,
            description: notificationChannelDescription,
            importance: Importance.high,
          ),
        );
    _notificationsReady = true;
  }

  static DateTime _lastTriggeredAt = DateTime.fromMillisecondsSinceEpoch(0);
  static String? _lastTriggeredKeyword;

  /// Dedupe window: stops the SAME utterance from firing twice (spotter
  /// emits the hit on consecutive frames of one "help me"). A new utterance
  /// after this window, or after a cancel/reset, triggers again with no limit.
  /// (User-requested 1s: a repeated "help me" re-triggers almost immediately.)
  static const _dedupeWindow = Duration(seconds: 1);

  static const _enabledPrefKey = 'zelda_voice_guard_enabled';
  static const _triggerWordsPrefKey = 'zelda_trigger_words';
  static const _resetCooldownEvent = 'reset_cooldown';
  static const _setForegroundEvent = 'set_foreground';
  static const _serviceReadyEvent = 'service_ready';
  /// Public alias of [_resetCooldownEvent] for the BG SOS executor
  /// (separate library; the private name is not visible there).
  static const String resetCooldownEventName = 'reset_cooldown';
  static const _pendingTriggerKey = 'zelda_pending_sos_trigger';
  // Main-isolate mic verdict (reliable — has an Activity). The BG isolate's
  // record.hasPermission() lies (returns false on MIUI despite OS grant), so
  // the BG engine trusts this flag instead of its own check.
  static const _micGrantedMainKey = 'zelda_voice_mic_granted_main';
  // Boot-stage marker shared main<->BG via prefs (see markStage): the BG
  // engine stamps each startup step so a stall/crash names the exact step.
  static const _stageKey = 'zelda_voice_boot_stage';
  static const _stageTimeKey = 'zelda_voice_boot_stage_at';

  static bool _appInForeground = true;

  /// Reset the trigger dedupe in the background isolate so a NEW utterance of
  /// the keyword can trigger SOS again immediately (after cancel/finish).
  /// Best-effort: even if this cross-isolate event is ever lost, the short
  /// [_dedupeWindow] self-heals within a few seconds.
  static void resetDetectionCooldown() {
    // Best-effort: in plain unit/widget tests (and before the BG service is
    // bound) this invoke has no receiver and must not crash callers.
    try {
      _service.invoke(_resetCooldownEvent);
    } catch (_) {}
  }

  /// Record that a trigger word was detected by the background isolate so
  /// that if the app is woken from the full-screen notification the SOS can be
  /// triggered even if the detection event itself was lost while the main
  /// isolate was dead/paused.
  static Future<void> _markPendingTrigger() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        _pendingTriggerKey, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<void> _clearPendingTrigger() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingTriggerKey);
  }

  /// Consume a pending SOS trigger (set by the background isolate) if it is
  /// still fresh. Returns true when a trigger was fired. Called after the UI
  /// has subscribed to [detections] so the event is not lost on cold start.
  static Future<bool> consumePendingTrigger() async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_pendingTriggerKey);
    if (ts == null) return false;
    await _clearPendingTrigger();
    final age = DateTime.now().millisecondsSinceEpoch - ts;
    if (age < 0 || age > 60000) return false; // stale
    // Never replay a trigger that predates the last confirmed cancellation of
    // this session: it would start a brand-new countdown after the user
    // already cancelled (the duplicate cancel-screen bug).
    final cancelledAt = prefs.getInt(SosExecutor.cancelledAtKey) ?? 0;
    final session = (prefs.getString(SosExecutor.sessionIdKey) ?? '').trim();
    final cancelledSession =
        (prefs.getString(SosExecutor.cancelledSessionIdKey) ?? '').trim();
    final replayOfCancelled = cancelledAt > 0 &&
        (session.isEmpty || session == cancelledSession) &&
        ts <= cancelledAt;
    if (replayOfCancelled) {
      await VoiceGuardService.flog(
        'bg',
        'pending voice trigger ignored (cancelled session)',
      );
      return false;
    }
    developer.log(
      'Firing pending SOS trigger from background',
      name: 'VoiceGuard',
    );
    _detectionController.add(VoiceGuardService.keywords.first);
    return true;
  }

  static Future<void> _firePendingTriggerIfRecent() async {
    await consumePendingTrigger();
  }

  static Future<bool> wasEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledPrefKey) ?? false;
  }

  /// Key stashing the pre-logout voice flag so login can restore it.
  /// (Logout clears [_enabledPrefKey]; without the stash the choice is lost.)
  static const preLogoutKey = 'zelda_voice_guard_enabled_prelogout';

  /// Raw tri-state read of the voice flag: null = never set (fresh install).
  /// Lets callers distinguish an explicit user-off from "no choice recorded".
  static Future<bool?> getEnabledPrefRaw() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledPrefKey);
  }

  static Future<void> setEnabledPref(bool enabled) async {
    // Timeout-guarded: on some HyperOS builds the prefs channel can stall;
    // a stall here must never wedge the toggle silently (best-effort write).
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      await prefs
          .setBool(_enabledPrefKey, enabled)
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      developer.log('setEnabledPref failed (best-effort): $e',
          name: 'VoiceGuard', level: 1000);
    }
  }

  /// Trigger words persisted by the custom-word setup (shared by the main
  /// and background isolates via prefs — statics are per-isolate).
  static Future<List<String>> getTriggerWords() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_triggerWordsPrefKey);
    if (raw == null || raw.isEmpty) return List.of(defaultTriggerWords);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final words = decoded
            .whereType<String>()
            .map((w) => w.trim())
            .where((w) => w.isNotEmpty)
            .toList();
        if (words.isNotEmpty) return words;
      }
    } catch (_) {}
    return List.of(defaultTriggerWords);
  }

  static Future<void> _persistTriggerWords(List<String> words) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_triggerWordsPrefKey, jsonEncode(words));
  }

  /// Save custom trigger words from the dashboard setup. Pre-validates
  /// against the on-device token set when the model bundle is already
  /// downloaded (unsupported words are dropped with a clear message, never
  /// saved silently). Restarts the listener so the spotter rebuilds with
  /// the new words immediately.
  static Future<({bool ok, List<String> words, String message})>
      setTriggerWords(List<String> words) async {
    final cleaned =
        words.map((w) => w.trim()).where((w) => w.isNotEmpty).toList();
    if (cleaned.isEmpty) {
      return (ok: false, words: await getTriggerWords(), message: 'Enter at least one word.');
    }
    // Keep the list small — every extra word costs spotter CPU on every frame.
    final limited = cleaned.take(3).toList();

    // Pre-validate when the bundle is already on disk (first run downloads
    // it in the background isolate instead — which validates again there).
    List<String> accepted = limited;
    List<String> dropped = const [];
    final tokenSet = await _cachedTokenSet();
    if (tokenSet != null) {
      accepted = [];
      dropped = [];
      for (final w in limited) {
        if (_wordSupported(w, tokenSet)) {
          accepted.add(w);
        } else {
          dropped.add(w);
        }
      }
      if (accepted.isEmpty) {
        return (
          ok: false,
          words: await getTriggerWords(),
          message:
              '"${dropped.join(', ')}" is not supported by the on-device listener. Try a common English word.',
        );
      }
    }

    await _persistTriggerWords(accepted);
    keywords = List.of(accepted);

    // Restart the engine so the spotter rebuilds with the new words now
    // (a running service would otherwise keep the old keywords until the
    // next toggle). NOT stop(): that would clear the enabled pref — invoke
    // the isolate's stop listener directly, wait, then start fresh.
    if (await _service
        .isRunning()
        .timeout(const Duration(seconds: 3))
        .catchError((_) => false)) {
      try {
        _service.invoke('stop');
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 1));
      await start();
    }

    final note = dropped.isEmpty
        ? ''
        : ' Skipped unsupported: "${dropped.join(', ')}".';
    final names = accepted.map((w) => '"$w"').join(', ');
    return (
      ok: true,
      words: List.of(accepted),
      message: 'Trigger saved: $names.$note Voice protection restarted — say it to test.',
    );
  }

  /// Tokens file from a previous download, if present (null on first run
  /// before the background isolate downloads the bundle).
  static Future<Set<String>?> _cachedTokenSet() async {
    try {
      final paths = await KeywordModelManager.cachedPaths();
      if (paths == null) return null;
      return KeywordModelManager.loadTokenSet(paths.tokens);
    } catch (_) {
      return null;
    }
  }

  /// Every whitespace-separated part must exist as a BPE token (▁PART).
  static bool _wordSupported(String word, Set<String> tokenSet) {
    final parts = word.toUpperCase().split(RegExp(r'\s+'));
    if (parts.isEmpty) return false;
    for (final part in parts) {
      if (part.isEmpty) continue;
      if (!tokenSet.contains('▁$part')) return false;
    }
    return true;
  }

  /// Map a raw spotter hit back to the phrase the user chose.
  ///
  /// sherpa may echo the buffer line either with or without the
  /// ":score #threshold" suffix, so every plausible form is tried before
  /// falling back to the first active word.
  static String _displayFor(
    String hit,
    Map<String, String> displayByBufLine,
    List<String> activeWords,
  ) {
    final direct = displayByBufLine[hit];
    if (direct != null) return direct;
    final withoutSuffix =
        hit.split(' :').first.split(' #').first.trim();
    final viaTokens = displayByBufLine[withoutSuffix];
    if (viaTokens != null) return viaTokens;
    return activeWords.isEmpty ? hit : activeWords.first;
  }

  /// The BPE token sequence for a trigger phrase, or null if the model can
  /// never hear it.
  ///
  /// 1. the build-time table (assets/kws_keywords.txt) has the exact
  ///    segmentation for the common emergency phrases;
  /// 2. otherwise fall back to the whole-word form, which only works for
  ///    words the BPE happens to keep whole ("HELP", "POLICE", ...).
  static String? _tokensFor(
    String phrase,
    Map<String, String> keywordTable,
    Set<String> tokenSet,
  ) {
    final key = phrase.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
    if (key.isEmpty) return null;
    final t = keywordTable[key];
    if (t != null && t.isNotEmpty) return t;
    final parts = key.split(' ');
    final buf = <String>[];
    for (final p in parts) {
      if (p.isEmpty) continue;
      if (!tokenSet.contains('▁$p')) return null;
      buf.add('▁$p');
    }
    return buf.isEmpty ? null : buf.join(' ');
  }

  static Stream<String> get detections => _detectionController.stream;
  static Stream<bool> get statusStream => _statusController.stream;
  static Stream<String> get errors => _errorController.stream;
  /// Live SOS executor snapshots (BG authority): state, remaining, source,
  /// busy/cancelled/sent flags. The dashboard mirrors these — it never runs
  /// its own timers while a BG engine is alive.
  static Stream<Map<String, Object?>> get sosStateStream =>
      _sosStateController.stream;
  /// The BG executor asks the open app to run its CameraController recording
  /// (only fires while the app is foregrounded at countdown end).
  static Stream<void> get appRecordingRequests =>
      _appRecordingController.stream;

  /// True while the background engine is receiving only exact-zero mic data:
  /// the OS silences capture for ineligible background services (observed on
  /// MIUI/Android 15 — a boot-started engine gets digital zeros until the app
  /// has a visible activity once). Driven by the 10 s 'heartbeat' event; the
  /// dashboard must not claim "Listening" while this is true.
  static final ValueNotifier<bool> micDegraded = ValueNotifier<bool>(false);

  static bool _configured = false;

  static Future<void> initialize() async {
    try {
      await _ensureNotificationsInitialized()
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      await flog('init', 'notifications init failed (continuing): $e');
    }

    WidgetsBinding.instance.addObserver(_LifecycleObserver());

    // Main-isolate copy of the persisted trigger words (background isolate
    // loads its own copy from the same pref key). Timeout-guarded: a prefs
    // stall must never wedge app startup (runApp waits on initialize()).
    try {
      keywords = await getTriggerWords()
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      await flog('init', 'getTriggerWords failed (using defaults): $e');
      keywords = List.of(defaultTriggerWords);
    }

    if (_configured) return;
    _configured = true;

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        autoStartOnBoot: true,
        isForegroundMode: true,
        notificationChannelId: notificationChannelId,
        initialNotificationTitle: 'ZELDA Voice Protection',
        initialNotificationContent: 'Listening for trigger word',
        foregroundServiceNotificationId: fgsNotificationId,
        // microphone: KWS listener. location: the BG SOS executor takes the
        // fresh SOS fix + live tracking from this same isolate (background
        // location needs the location FGS type + ACCESS_BACKGROUND_LOCATION).
        foregroundServiceTypes: [
          AndroidForegroundType.microphone,
          AndroidForegroundType.location,
        ],
      ),
      iosConfiguration: IosConfiguration(autoStart: false),
    );

    _service.on(_detectionEvent).listen((event) {
      if (event != null && event['keyword'] != null) {
        developer.log(
          'Keyword detected: ${event['keyword']}',
          name: 'VoiceGuard',
        );
        _detectionController.add(event['keyword'] as String);
      }
    });
    _service.on(_statusEvent).listen((event) {
      if (event != null && event['running'] != null) {
        developer.log(
          'Service status: running=${event['running']}',
          name: 'VoiceGuard',
        );
        _lastRunning = event['running'] as bool;
        _statusController.add(event['running'] as bool);
      }
    });
    _service.on(_errorEvent).listen((event) {
      if (event != null && event['error'] != null) {
        developer.log(
          'Service error: ${event['error']}',
          name: 'VoiceGuard',
          level: 1000,
        );
        _errorController.add(event['error'] as String);
      }
    });
    _service.on(_serviceReadyEvent).listen((_) {
      // Background isolate is up; tell it whether the app is in the foreground
      // so it knows whether to wake the UI on a keyword detection.
      _service.invoke(
        _setForegroundEvent,
        {'foreground': _appInForeground},
      );
    });
    // Live mic-health heartbeat: the background isolate reports whether the
    // engine hears real audio or exact zeros; the dashboard mirrors it so the
    // status line never claims "Listening" while capture is silenced.
    _service.on('heartbeat').listen((event) {
      final degraded = event != null && event['degraded'] == true;
      if (degraded != micDegraded.value) micDegraded.value = degraded;
    });
    // BG SOS executor snapshots (SosExecutor.sosStateEvent). The dashboard
    // mirrors these so an app opened mid-SOS shows the LIVE countdown.
    _service.on('sos_state').listen((event) {
      if (event == null) return;
      try {
        _sosStateController.add(Map<String, Object?>.from(event as Map));
      } catch (_) {}
    });
    // BG asks the open app to record with the CameraController pipeline
    // (SosExecutor.sosStartAppRecording); the controller reports back via
    // SosExecutor.onAppRecordingDone.
    _service.on('sos_start_app_recording').listen((_) {
      if (!_appRecordingController.isClosed) _appRecordingController.add(null);
    });
  }

  static Future<void> start() async {
    // Main-isolate verdict (reliable — has an Activity). Stash it for the BG
    // isolate, whose own record.hasPermission() is untrustworthy (MIUI
    // returns false there despite the OS grant).
    // Every await here is timeout-guarded: on HyperOS a permission prompt
    // (notably ignoreBatteryOptimizations) or the prefs channel can hang
    // forever, which used to leave the dashboard toggle fake-ON with zero
    // error surfacing. Timeouts turn a silent hang into a loud failure.
    await flog('main', 'start() entry');
    var micGranted = false;
    try {
      final micStatus = await Permission.microphone
          .request()
          .timeout(const Duration(seconds: 10));
      micGranted = micStatus.isGranted;
      await flog('main', 'mic request done granted=$micGranted');
    } catch (e) {
      await flog('main', 'mic request stalled: $e');
      developer.log('mic permission request stalled: $e',
          name: 'VoiceGuard', level: 1000);
    }
    try {
      await Permission.notification
          .request()
          .timeout(const Duration(seconds: 8));
      await flog('main', 'notification request done');
    } catch (e) {
      await flog('main', 'notification request stalled: $e');
    }
    try {
      await Permission.ignoreBatteryOptimizations
          .request()
          .timeout(const Duration(seconds: 8));
      await flog('main', 'battery-opt request done');
    } catch (e) {
      await flog('main', 'battery-opt request stalled: $e');
    }
    // Background SOS needs a background location fix for the case payload
    // + live tracking. Best-effort: denial only degrades the fix to the
    // last-known/foreground position, never blocks voice protection.
    try {
      final loc = await Permission.locationAlways
          .request()
          .timeout(const Duration(seconds: 8));
      await flog('main', 'locationAlways request done granted=${loc.isGranted}');
    } catch (e) {
      await flog('main', 'locationAlways request stalled: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      await prefs
          .setBool(_micGrantedMainKey, micGranted)
          .timeout(const Duration(seconds: 5));
      await flog('main', 'mic verdict stashed granted=$micGranted');
    } catch (e) {
      await flog('main', 'mic verdict stash failed: $e');
      developer.log('mic verdict stash failed (best-effort): $e',
          name: 'VoiceGuard', level: 1000);
    }
    // NEVER blindly startService(): on an already-running service the
    // re-delivery re-arms the system's FGS timeout while the plugin's
    // runService() early-returns ("already running") WITHOUT re-promoting.
    // If that service lost foreground state (background restart ⇒ mic-FGS
    // promotion denied, exception swallowed by the plugin), the process
    // dies ~30 s later with ForegroundServiceDidNotStartInTimeException.
    // So: fresh start only when down; when already up, ask the live BG
    // isolate to re-promote itself (app is foreground here ⇒ allowed).
    // Stamp the boot attempt so the watchdog can tell "isolate never ran"
    // apart from "isolate died mid-boot" (BG stamps overwrite this).
    await markStage('main-start');
    // startService() itself is NOT optional when down — it must run so the
    // watchdog below can verify the engine actually started.
    final alreadyRunning = await _service
        .isRunning()
        .timeout(const Duration(seconds: 3))
        .catchError((_) => false);
    if (alreadyRunning) {
      await flog('main',
          'service already running — requesting re-promote + engine boot check');
      try {
        _service.invoke('promote_to_foreground');
        _service.invoke('boot_engine');
      } catch (_) {}
    } else {
      await flog('main', 'calling startService()');
      await _service.startService().timeout(const Duration(seconds: 15));
      await flog('main', 'startService() returned');
    }

    // Watchdog: the dashboard toggle used to stay fake-ON when the native
    // service never came up. Wait for the engine-up signal (statusEvent
    // running:true, sent after the mic loop is live) instead of just
    // isRunning(): a first run downloads ~13 MB before the engine is up,
    // which takes far longer than any fixed short poll. Distinguishes three
    // outcomes: (1) service never starts — battery/permission kill;
    // (2) service starts then dies — native crash during boot;
    // (3) service alive but engine never ready — download/spotter/mic stall,
    // with the last BG stage marker naming the exact step.
    // Sticky seed + live re-query: ENGINE-UP may have fired before this
    // isolate subscribed (fast cached-model boot beats main to it; or the
    // activity was recreated while BG kept running). Broadcast drops events
    // with zero listeners, so without this the watchdog waits 90 s for an
    // event that already happened, then raises a false STALL. A dead engine
    // simply never replies and the poll loop below reports the true state.
    var engineUp = _lastRunning;
    final statusSub = _statusController.stream.listen((running) {
      _lastRunning = running;
      if (running) engineUp = true;
    });
    VoiceGuardService.serviceInvoke('query_status');
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      final fastFailAt = deadline.subtract(const Duration(seconds: 75));
      var runningSeen = false;
      var polls = 0;
      while (DateTime.now().isBefore(deadline)) {
        if (engineUp) {
          await flog('main', 'watchdog: engineUp signal received, success');
          return;
        }
        var running = false;
        try {
          running =
              await _service.isRunning().timeout(const Duration(seconds: 3));
        } catch (_) {
          // Poll timeout/channel error counts as "not running yet".
        }
        if (running) {
          runningSeen = true;
          if (polls % 10 == 0) {
            await flog('main', 'watchdog: service running, engineUp=$engineUp');
          }
        } else if (runningSeen) {
          await flog('main', 'watchdog: DIED-AFTER-RUNNING stage=${await readStage()}');
          throw StateError(
              'Voice engine died during startup (background service stopped). '
              'Last stage: ${await readStage()}. Try again; if it repeats, '
              'the on-device listener is crashing on this phone.');
        } else if (DateTime.now().isAfter(fastFailAt)) {
          await flog('main', 'watchdog: FAST-FAIL never-started stage=${await readStage()}');
          throw StateError(
              'Voice engine did not start (background service not running after 15 s). '
              'Set battery to Unrestricted for ZELDA, then toggle again.');
        }
        await Future.delayed(const Duration(seconds: 1));
        polls++;
      }
      if (engineUp) {
        await flog('main', 'watchdog: engineUp at deadline, success');
        return;
      }
      await flog('main', 'watchdog: 90s STALL stage=${await readStage()}');
      throw StateError(
          'Voice engine is starting but not ready after 90 s. '
          'Last stage: ${await readStage()}. '
          'Check internet for the one-time ~13 MB model download, then toggle again.');
    } finally {
      await statusSub.cancel();
    }
  }

  static Future<void> stop() async {
    // Observability only: log the voice-OFF path (was log-silent). No
    // start/stop semantics changed — same pref write + same unconditional
    // invoke, with best-effort flog lines around them (flog never throws).
    await flog('main', 'stop() entry (voice-off requested)');
    await setEnabledPref(false);
    await flog('main', 'stop() enabled pref cleared, invoking bg stop');
    // Unconditional: invoking a non-running service is harmless, and gating
    // on isRunning() risks skipping a genuine stop. Delivery to a live
    // service may queue behind engine work, but it is never lost.
    try {
      _service.invoke('stop');
    } catch (_) {}
    await flog('main', 'stop() invoke done');
  }

  static Future<bool> isRunning() =>
      _service.isRunning().timeout(const Duration(seconds: 3)).catchError((_) => false);

  /// File-based debug log (voice-debug.log in the app documents dir).
  /// Logcat carries zero Flutter lines on MIUI, and main-side prefs writes
  /// vanish on this phone, so stages are ALSO appended here — readable via
  /// run-as + cat with no app cooperation needed. Best-effort, never throws.
  static Future<void> flog(String tag, String msg) async {
    try {
      final dir = await getApplicationDocumentsDirectory()
          .timeout(const Duration(seconds: 5));
      final f = File('${dir.path}/voice-debug.log');
      await f
          .writeAsString(
            '${DateTime.now().toIso8601String()} [$tag] $msg\n',
            mode: FileMode.append,
            flush: true,
          )
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// Best-effort boot-stage marker shared between the main and background
  /// isolates via prefs. The BG engine stamps each startup step; if the
  /// service dies or stalls, the watchdog reads the last stamp so the
  /// failure names the EXACT step instead of a blind "did not start".
  static Future<void> markStage(String stage) async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      await prefs
          .setString(_stageKey, stage)
          .timeout(const Duration(seconds: 5));
      await prefs
          .setInt(_stageTimeKey, DateTime.now().millisecondsSinceEpoch)
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  static Future<String> readStage() async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));
      final stage = prefs.getString(_stageKey) ?? 'none (isolate never booted)';
      final at = prefs.getInt(_stageTimeKey);
      if (at == null) return stage;
      final age =
          DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(at));
      return '$stage (${age.inSeconds}s ago)';
    } catch (_) {
      return 'unreadable';
    }
  }

  /// Restart the background service if the user previously enabled voice
  /// protection (used when the OS kills the process/isolate while backgrounded).
  static Future<void> restartIfNeeded() async {
    if (!await wasEnabled()) return;
    if (await isRunning()) return;
    await start();
  }

  /// Post a high-priority notification with full-screen intent so the app is
  /// brought to the foreground when a trigger word is detected while the
  /// app is in the background.
  static Future<void> showEmergencyNotification({required String keyword}) async {
    await _ensureNotificationsInitialized();
    await _notifications.show(
      id: alarmNotificationId,
      title: '🚨 ZELDA SOS TRIGGERED',
      body: 'Heard "$keyword". Opening app to send SOS...',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          notificationChannelId,
          notificationChannelName,
          channelDescription: notificationChannelDescription,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          fullScreenIntent: true,
        ),
      ),
    );
  }

  /// Show the emergency notification FROM the background isolate. The plugin
  /// instance and initialization are per-isolate, so this ensures the
  /// notification channel is ready in the current isolate before posting.
  static Future<void> showEmergencyNotificationFromBackground({
    required String keyword,
  }) async {
    await _ensureNotificationsInitialized();
    await _notifications.show(
      id: alarmNotificationId,
      title: '🚨 ZELDA SOS TRIGGERED',
      body: 'Heard "$keyword". Opening app to send SOS...',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          notificationChannelId,
          notificationChannelName,
          channelDescription: notificationChannelDescription,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          fullScreenIntent: true,
        ),
      ),
    );
  }
}

@pragma('vm:entry-point')
Future<void> _onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  debugPrint('VoiceGuard BG isolate started');
  await VoiceGuardService.flog('bg', 'isolate booted');

  // Stage updates on the FGS notification text — observable on-device via
  // dumpsys even when Flutter logs never reach logcat (seen on Redmi).
  void note(String stage) {
    if (service is AndroidServiceInstance) {
      unawaited(
        service.setForegroundNotificationInfo(
          title: 'Voice Protection',
          content: stage,
        ),
      );
    }
  }

  note('Starting voice guard…');

  KeywordSpotter? spotter;
  OnlineStream? kwsStream;
  AudioRecorder? recorder;
  StreamSubscription<List<int>>? pcmSub;
  // Live ENGINE-UP state for the main isolate's query_status round-trip
  // (a state the watchdog can ask for, not an event it might have missed).
  var engineRunning = false;

  // Register the stop handler FIRST — before any fallible engine work.
  // If model/mic setup throws, _onStart returns early via catch; a late
  // registration would leave a failed service unstoppable (toggle OFF =
  // no-op, toggle ON = silent no-op on the already-running service).
  service.on('stop').listen((_) async {
    // Observability only: the voice-OFF path was log-silent. Same teardown
    // order and semantics — flog lines bracket the existing steps.
    await VoiceGuardService.flog('bg', 'stop received (voice-off)');
    // Unconditional: the ONLY senders of 'stop' are stop() (genuine user
    // off) and setTriggerWords() (restart — start() follows within ~1 s),
    // so every stop is honored. No pref reads (no cross-engine staleness),
    // no gates that can skip a genuine stop.
    // Immediate feedback FIRST: the notification text changes within ~1 s
    // even if the teardown below is slow, and the mic is released FIRST
    // so the green dot drops fast. Then free the native spotter sessions
    // (no memory leaks) and stopSelf().
    note('Turning off…');
    await pcmSub?.cancel();
    if (recorder != null) {
      try {
        await recorder?.stop();
      } catch (_) {}
    }
    kwsStream?.free();
    spotter?.free();
    engineRunning = false;
    await VoiceGuardService.flog('bg', 'stop teardown done, stopping self');
    service.stopSelf();
  });

  // Re-promote to foreground on request from the main isolate. A service
  // (re)started while the app is in the background is denied mic|location
  // FGS promotion (SecurityException, swallowed by the plugin) yet keeps
  // running unpromoted: engine boots, ENGINE-UP fires, watchdog passes —
  // but the next startService() re-delivery re-arms the system's FGS
  // timeout while runService() early-returns without re-promoting, and the
  // process dies ~30 s later with ForegroundServiceDidNotStartInTime
  // (killed PIDs 1071/22109 on rotation-recreate/app-reopen). The main
  // isolate sends this only when it finds the service already running; the
  // app is foreground then, so startForeground() is allowed and heals the
  // service back to full FGS protection. Idempotent — safe to repeat.
  service.on('promote_to_foreground').listen((_) async {
    try {
      if (service is AndroidServiceInstance) {
        await service.setAsForegroundService();
        await VoiceGuardService.flog('bg', 're-promoted to foreground');
      }
    } catch (e) {
      await VoiceGuardService.flog('bg', 're-promote failed: $e');
    }
  });

  // The main isolate asks for the CURRENT running state on every start():
  // ENGINE-UP is a state, not an event — a broadcast fired before main
  // subscribed is dropped, so main re-queries instead of trusting its luck.
  // No-op when the engine is dead (the watchdog then reports the true state).
  service.on('query_status').listen((_) {
    service.invoke(VoiceGuardService._statusEvent, {'running': engineRunning});
  });

  var appInForeground = false;

  service.on(VoiceGuardService._resetCooldownEvent).listen((_) {
    VoiceGuardService._lastTriggeredAt =
        DateTime.fromMillisecondsSinceEpoch(0);
    VoiceGuardService._lastTriggeredKeyword = null;
    developer.log('Trigger dedupe reset by UI', name: 'VoiceGuard');
  });

  service.on(VoiceGuardService._setForegroundEvent).listen((event) {
    if (event != null && event['foreground'] != null) {
      appInForeground = event['foreground'] as bool;
      developer.log(
        'App foreground=$appInForeground',
        name: 'VoiceGuard',
      );
    }
  });

  // Tell the main isolate we are listening so it can reply with the current
  // foreground state. If the app process was killed (recents) the main isolate
  // is gone and we correctly keep appInForeground = false.
  service.invoke(VoiceGuardService._serviceReadyEvent);
  await VoiceGuardService.markStage('isolate-booted');

  // ── BG SOS executor boots FIRST, unconditionally ──
  // Cheap (prefs + timers only): power-button triggers get a live executor
  // even when voice listening is disabled, and the 5s countdown no longer
  // waits for the app to open. The spotter/mic below only starts when voice
  // protection is enabled.
  await SosExecutor.onBoot(service, () => appInForeground);
  await VoiceGuardService.markStage('executor-up');
  await VoiceGuardService.flog('bg', 'executor-up');

  bool voiceOn = true;
  // Standby heartbeat, cancelled once the engine boots (post-login heal via
  // boot_engine). Declared here so both the standby branch and bootEngine
  // can reach it. No SOS path touches this.
  Timer? standbyHeartbeat;
  try {
    voiceOn = await VoiceGuardService.wasEnabled()
        .timeout(const Duration(seconds: 5));
  } catch (e) {
    await VoiceGuardService.flog('bg', 'enabled-pref unreadable, attempting mic: $e');
  }
  if (!voiceOn) {
    note('SOS guard standby');
    await VoiceGuardService.markStage('engine-standby');
    await VoiceGuardService.flog('bg', 'STANDBY (voice off, executor only)');
    service.invoke(VoiceGuardService._statusEvent, {'running': false});
    standbyHeartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      service.invoke('heartbeat');
    });
    // NO return here (was: early return): the boot_engine handler is
    // registered at the end of this function. A fresh-install isolate boots
    // in standby (voice pref unset), then the user logs in and the dashboard
    // heal invokes boot_engine — with the early return that invoke landed on
    // no listener and voice stayed silently dead despite the toggle reading
    // ON. Fall through so the handler is always live; the guard below keeps
    // standby from booting the engine by itself.
  }

  // ── Keyword-spotter engine (KWS only, no speech-to-text stage) ──
  // The Zipformer spotter hears trigger WORDS straight from the mic stream,
  // so there is no transcription step: hits fire directly (low latency),
  // the download stays small (~13 MB, cached after first run), and the
  // per-frame cost is a fraction of a full recognizer. Custom words from
  // the dashboard are validated against the bundle's tokens below — a word
  // the bundle cannot tokenize could never fire, so it falls back to the
  // default with a clear error instead of silently never working.
  // Same downstream path as before: dedupe + pending-trigger +
  // full-screen alarm in fireKeyword, so app-off hits still wake the phone.
  var engineBooting = false;
  // True when the last boot attempt failed (model download / mic stream /
  // catch-all). While true, the dashboard banner must not claim Listening —
  // the heartbeat carries degraded=true until a boot succeeds.
  var engineFailed = false;
  // Mic-health telemetry + stall watchdog (permanent). Chunk counters and
  // window energy, written by the mic chunk loop and read by the 10s
  // heartbeat (both capture this scope; declared here so all users come
  // after in source order). If the stream delivers zero chunks for 2
  // consecutive heartbeats while the engine is listening (not paused by the
  // executor for native recording), the heartbeat restarts it — self-heals
  // a silently-dead AudioRecord (seen once: deaf-when-locked on a single
  // anomalous boot while healthy everywhere else).
  int diagChunks = 0;
  double diagSumSq = 0.0;
  int diagSamples = 0;
  // Chunks that PASSED the VAD gate and were fed to the spotter — this is
  // what separates "deaf spotter" from "dead mic" in a post-mortem.
  int diagDecoded = 0;
  int diagLastChunkMs = 0;
  bool micPausedByExecutor = false;
  bool micEverChunked = false;
  int micSilentBeats = 0;
  int micStallRestarts = 0;
  // Zero-energy beats: consecutive heartbeats with chunks arriving but EXACT
  // zero energy (background-muted/stuck AudioRecord passes the count check).
  int micZeroBeats = 0;
  // VAD-gate skips this window (telemetry for CPU savings).
  int vadSkipped = 0;
  // Periodic-refresh pacing: stamped when the engine reaches ENGINE-UP and
  // re-stamped on every rebuild (see VoiceGuardService._kwsRefreshPeriod).
  int engineUpSinceMs = 0;
  int lastRefreshMs = 0;
  // Engine boot, re-runnable on demand (see the boot_engine handler at the
  // end of this function): after a stop() teardown the isolate may stay
  // alive engine-down (a system reboot lands it in STANDBY and the standby
  // path never boots the engine), so start()/auto-start heal it through
  // here instead of only re-promoting. Returns true when the engine is up.
  Future<bool> bootEngine({bool force = false, String forceReason = 'stall'}) async {
    if (engineRunning && !force) {
      await VoiceGuardService.flog('bg', 'boot_engine: already up');
      service.invoke(VoiceGuardService._statusEvent, {'running': true});
      return true;
    }
    if (force && engineRunning) {
      // Stall watchdog: engine alive but mic stream silent — tear down the
      // audio path (mirrors the stop-handler teardown, minus stopSelf) and
      // fall through to the full boot flow below (cached bundle: fast).
      // Uses only _onStart-scope state (all declared above this function).
      if (engineBooting) {
        await VoiceGuardService.flog(
            'bg', 'boot_engine: boot already in progress, skip force');
        return false;
      }
      await VoiceGuardService.flog('bg', forceReason == 'refresh'
          ? 'spotter refresh: force-rebuilding KWS session'
          : 'mic STALL: no chunks for 20s+, rebooting engine (attempt $micStallRestarts)');
      try {
        await pcmSub?.cancel();
      } catch (_) {}
      pcmSub = null;
      if (recorder != null) {
        try {
          await recorder?.stop();
        } catch (_) {}
      }
      try {
        kwsStream?.free();
      } catch (_) {}
      kwsStream = null;
      try {
        spotter?.free();
      } catch (_) {}
      spotter = null;
      engineRunning = false;
    }
    if (engineBooting) {
      await VoiceGuardService.flog(
          'bg', 'boot_engine: boot already in progress');
      return false;
    }
    engineBooting = true;
    try {
    await VoiceGuardService.markStage('engine-start');
    await VoiceGuardService.flog('bg', 'engine-start');
    initBindings();
    await VoiceGuardService.markStage('bindings-ok');
    await VoiceGuardService.flog('bg', 'bindings-ok');
    await VoiceGuardService.markStage('download-start');
    await VoiceGuardService.flog('bg', 'download-start');
    late final KwsModelPaths paths;
    try {
      paths = await KeywordModelManager.ensureBundle(
        onProgress: (stage, done, total) {
          debugPrint(
            '[VoiceGuard] model $stage '
            '${(done / 1024 / 1024).toStringAsFixed(1)} / '
            '${(total / 1024 / 1024).toStringAsFixed(1)} MB',
          );
          note(
            'Models $stage '
            '${(done / 1024 / 1024).toStringAsFixed(0)} / '
            '${(total / 1024 / 1024).toStringAsFixed(0)} MB',
          );
        },
      );
    } catch (e) {
      debugPrint('[VoiceGuard] model download failed: $e');
      await VoiceGuardService.flog('bg', 'DOWNLOAD-FAILED: $e');
      service.invoke(
        VoiceGuardService._errorEvent,
        {'error': 'Voice model unavailable: $e'},
      );
      engineFailed = true;
      return false;
    }
    debugPrint('VoiceGuard KWS models ready');
    note('Models ready, loading listener…');
    await VoiceGuardService.markStage('models-ready');
    await VoiceGuardService.flog('bg', 'models-ready');

    // Trigger words (persisted custom setup, default "Help me") into the
    // BPE-keyword buffer the native spotter expects.
    //
    // The token sequence is NOT a hand-rolled "▁" + whole-word join: the
    // model's BPE splits words into sub-words ("EMERGENCY" is
    // "▁E M ER G EN C Y", "SAVE ME" is "▁SA VE ▁ME"). A whole-word join
    // therefore only ever works for single-token words like "HELP", and
    // silently rejects "Emergency" / "Save me". The exact BPE segmentation
    // for the common emergency phrases is generated at build time with
    // sherpa-onnx-cli text2token and shipped in assets/kws_keywords.txt;
    // anything outside that table falls back to the whole-word form.
    //
    // keywordsBufSize MUST be the UTF-8 byte length of the buffer: native
    // treats a size-0 buffer as zero registered keywords and refuses to
    // create the spotter ("Failed to create kws").
    final persisted = await VoiceGuardService.getTriggerWords();
    final tokenSet = await KeywordModelManager.loadTokenSet(paths.tokens);
    final kwTable = await KeywordModelManager.loadKeywordTokens();

    final activeWords = <String>[];
    final bufLines = <String>[];
    for (final w in persisted) {
      final tokens = VoiceGuardService._tokensFor(w, kwTable, tokenSet);
      if (tokens == null) continue;
      activeWords.add(w);
      bufLines.add('$tokens :0.7 #0.10');
    }
    if (activeWords.isEmpty) {
      debugPrint('[VoiceGuard] no supported trigger words, using default');
      service.invoke(
        VoiceGuardService._errorEvent,
        {
          'error':
              'Trigger "${persisted.join(', ')}" is not supported by the on-device listener — using "Help me".'
        },
      );
      for (final w in VoiceGuardService.defaultTriggerWords) {
        final tokens = VoiceGuardService._tokensFor(w, kwTable, tokenSet);
        if (tokens == null) continue;
        activeWords.add(w);
        bufLines.add('$tokens :0.7 #0.10');
      }
    }
    final keywordsBuf = bufLines.join('\n');
    // KWS result echoes the matched buffer line — map it back to the
    // display-cased word for the SOS dialog ("Heard help me").
    final displayByBufLine = <String, String>{
      for (int i = 0; i < bufLines.length; i++)
        bufLines[i].split(' :').first: activeWords[i],
    };

    spotter = KeywordSpotter(
      KeywordSpotterConfig(
        model: OnlineModelConfig(
          transducer: OnlineTransducerModelConfig(
            encoder: paths.encoder,
            decoder: paths.decoder,
            joiner: paths.joiner,
          ),
          tokens: paths.tokens,
          numThreads: 2,
        ),
        keywordsBuf: keywordsBuf,
        keywordsBufSize: utf8.encode(keywordsBuf).length,
        // MEASURED on the real model with the real keyword buffer
        // (server/tools/kws_bench.py, 40 positives x 3 loudness levels,
        // 69 adversarial negatives):
        //   score 1.0 / threshold 0.25  -> 85% recall, 6 false alarms
        //   score 0.7 / threshold 0.10  -> 100% recall, 5 false alarms
        // A HIGHER boost score HURTS here (1.6 dropped recall to 60%), and
        // lowering the trigger threshold is what actually buys recall.
        keywordsScore: 0.7,
        keywordsThreshold: 0.10,
        numTrailingBlanks: 1,
      ),
    );
    kwsStream = spotter!.createStream();
    debugPrint('VoiceGuard KWS spotter created for: ${activeWords.join(', ')}');
    await VoiceGuardService.markStage('spotter-created');
    await VoiceGuardService.flog(
        'bg', 'spotter-created words=${activeWords.join('|')}');
    Future<void> fireKeyword(String keyword) async {
      final now = DateTime.now();
      final isDuplicate =
          now.difference(VoiceGuardService._lastTriggeredAt) <
              VoiceGuardService._dedupeWindow &&
          VoiceGuardService._lastTriggeredKeyword == keyword;
      if (isDuplicate) {
        developer.log(
          'Keyword "$keyword" already triggered recently, ignoring',
          name: 'VoiceGuard',
        );
        await VoiceGuardService.flog(
          'bg',
          'keyword dedupe-blocked: $keyword (window=${VoiceGuardService._dedupeWindow.inSeconds}s)',
        );
        return;
      }
      // Post-cancel grace: after an explicit user cancel, ambient voice
      // ("did it cancel?", TV dialogue, testing chatter) must not instantly
      // re-fire a new SOS — that loop feels exactly like "cancel doesn't
      // work". Manual/power triggers bypass this (checked only here).
      // The static timestamp covers this isolate; the persisted cancelled_at
      // covers native/BG-restart cancels where that static is lost.
      var cancelAge = SosExecutor.lastUserCancelAt == null
          ? null
          : now.difference(SosExecutor.lastUserCancelAt!);
      try {
        final prefs = await SharedPreferences.getInstance();
        final persisted = prefs.getInt(SosExecutor.cancelledAtKey) ?? 0;
        if (persisted > 0) {
          final persistedAge = now.difference(
              DateTime.fromMillisecondsSinceEpoch(persisted));
          if (cancelAge == null || persistedAge < cancelAge) {
            cancelAge = persistedAge;
          }
        }
      } catch (_) {}
      if (cancelAge != null && cancelAge < SosExecutor.postCancelVoiceGrace) {
        final remaining = SosExecutor.postCancelVoiceGrace.inSeconds -
            cancelAge.inSeconds;
        developer.log(
          'Keyword "$keyword" suppressed post-cancel (${remaining}s left)',
          name: 'VoiceGuard',
        );
        await VoiceGuardService.flog(
          'bg',
          'voice suppressed ${remaining}s post-cancel (grace=${SosExecutor.postCancelGraceSeconds}s)',
        );
        return;
      }
      VoiceGuardService._lastTriggeredAt = now;
      VoiceGuardService._lastTriggeredKeyword = keyword;
      developer.log('Keyword confirmed: $keyword', name: 'VoiceGuard');
      await VoiceGuardService.flog('bg', 'Keyword confirmed: $keyword');
      // BG executor is authoritative: the 5s cancel window starts HERE, in
      // this isolate, whether the app is open or not.
      unawaited(SosExecutor.onTrigger('voice:$keyword'));
      service.invoke(VoiceGuardService._detectionEvent, {'keyword': keyword});
      if (!appInForeground) {
        await VoiceGuardService._markPendingTrigger();
        // Single native full-screen alarm (SosAlarmActivity over home/lock
        // screen), posted by the persistent PowerGuardService poller — the
        // old Dart FSI notification is replaced by it (no duplicates).
        await SosExecutor.requestNativeAlarm();
      }
    }

    final mic = AudioRecorder();
    recorder = mic;

    Future<void> stopMicLoop() async {
      try {
        await pcmSub?.cancel();
      } catch (_) {}
      pcmSub = null;
      if (recorder != null) {
        try {
          await recorder?.stop();
        } catch (_) {}
      }
      await VoiceGuardService.flog('bg', 'mic loop paused by executor');
    }

    // (Re)starts the mic stream + KWS chunk loop. Idempotent: a live loop
    // is left alone. Returns false when the mic genuinely cannot start.
    Future<bool> startMicLoop() async {
    // Enforce the single-session invariant (the comment above always claimed
    // idempotence; now the code has it). A live loop must never be
    // double-started — two feeding listeners would decode every utterance
    // twice. All teardown paths (stop handler, executor pause, force rebuild)
    // null pcmSub first, so a genuine restart still passes.
    if (pcmSub != null) {
      await VoiceGuardService.flog('bg', 'startMicLoop skipped: loop already live');
      return true;
    }
    // Attempt-first mic open: the MAIN-isolate verdict stash lives in
    // FlutterSharedPreferences, which is ABSENT on this ROM (writes vanish),
    // and record.hasPermission() inside this BG isolate lies on MIUI (false
    // despite the OS grant). So just TRY startStream — a real denial throws
    // here and maps to the same permission-denied error below. The stash is
    // only logged for diagnostics.
    final bgPrefs = await SharedPreferences.getInstance();
    final mainSideGranted =
        bgPrefs.getBool(VoiceGuardService._micGrantedMainKey) ?? false;
    await VoiceGuardService.flog(
        'bg', 'mic-gate stash=$mainSideGranted, trying startStream');
    late final Stream<List<int>> pcm;
    try {
      pcm = await mic.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          // Phase 4 - let Android do the hard audio work:
          //  * VOICE_RECOGNITION source -> the platform enables its tuned
          //    capture path (better far-field sensitivity than plain MIC);
          //  * autoGain   -> hardware AGC, so a whisper is normalised by the
          //    DSP instead of relying only on our software AGC below;
          //  * echoCancel -> kills the phone's own speaker/earpiece bleed;
          //  * noiseSuppress -> attenuates steady background noise, which is
          //    what turns false alarms into a problem in a noisy street.
          // All of these are standard Android audio effects, so there is no
          // new native code and no extra CPU on our side.
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.voiceRecognition,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[VoiceGuard] mic startStream failed: $e');
      await VoiceGuardService.flog('bg', 'MIC-STREAM-FAILED: $e');
      service.invoke(
        VoiceGuardService._errorEvent,
        {'error': 'Microphone permission denied'},
      );
      engineFailed = true;
      return false;
    }

    // IMPORTANT: keep the per-chunk path light. The full-screen alarm +
    // pending-trigger write happen in fireKeyword without stalling the mic
    // loop (fired unawaited). The spot is reset on every hit so the SAME
    // utterance cannot re-fire on consecutive frames.
    // AGC + high-pass state, persisted across chunks.
    double hpPrev = 0.0;
    double hpState = 0.0;
    // Diagnostics: recent pre-AGC chunk RMS (for the SNR readout) and the
    // ambient noise floor, which only true silence is allowed to move.
    final List<double> rmsHistory = <double>[];
    double noiseFloor = 0.0006;
    pcmSub = pcm.listen((List<int> c) {
      diagChunks++;
      micEverChunked = true;
      diagLastChunkMs = DateTime.now().millisecondsSinceEpoch;
      final Uint8List chunk = c is Uint8List ? c : Uint8List.fromList(c);
      final int n = chunk.length ~/ 2;
      final Float32List samples = Float32List(n);
      double chunkSumSq = 0.0;
      for (int i = 0; i < n; i++) {
        int v = chunk[2 * i] | (chunk[2 * i + 1] << 8);
        if (v >= 32768) v -= 65536;
        final double s = v / 32768.0;
        // ~80 Hz high-pass: drop wind/HVAC rumble that trips the VAD and
        // confuses the spotter. First-order IIR, near-zero cost.
        // fc = fs*(1-r)/(2*pi) -> r = 0.968 gives ~81 Hz at 16 kHz.
        final double y = s - hpPrev + 0.968 * hpState;
        hpPrev = s;
        hpState = y;
        samples[i] = y;
        diagSumSq += y * y;
        diagSamples++;
        chunkSumSq += y * y;
      }
      final spot = spotter;
      final stream = kwsStream;
      if (spot == null || stream == null) return;
      // AGC: normalise quiet speech up to a target RMS so a whisper still
      // reaches the spotter. Gain clamped to [1, 20] so noise is not
      // amplified into a false trigger.
      double rms = 0.0;
      for (int i = 0; i < n; i++) { rms += samples[i] * samples[i]; }
      rms = math.sqrt(rms / (n == 0 ? 1 : n));
      // Noise-floor estimate + short RMS history, measured BEFORE the AGC
      // gain (AGC would flatten the very ratio we need here).
      if (n > 0) {
        rmsHistory.add(rms);
        if (rmsHistory.length > 12) { rmsHistory.removeAt(0); }
      }
      final double gain = rms < 1e-4 ? 1.0 : (0.05 / rms).clamp(1.0, 20.0);
      for (int i = 0; i < n; i++) { samples[i] *= gain; }
      // VAD gate (CPU saver, zero training): skip spotter decode on
      // true-silence chunks. Floor sits ~20x below quiet-room mean-square
      // (~0.0006) and infinitely above digital zero - whispered-nearby
      // speech reads far above it. Skips counted in mic-health.
      // Lowered from 0.00005 to 0.00002 so quiet/quiet-room speech is not
      // dropped before it reaches the spotter (the most common cause of "it
      // did not hear me" reports).
      if (n > 0 && chunkSumSq / n < 0.00002) {
        vadSkipped++;
        // ONLY true silence moves the noise floor. If speech moved it, a
        // quiet "Help me" would raise the floor and then look like noise -
        // the exact failure this whole stage must avoid.
        noiseFloor = noiseFloor * 0.9 + rms * 0.1;
        return;
      }
      diagDecoded++;
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      while (spot.isReady(stream)) {
        spot.decode(stream);
      }
      final hit = spot.getResult(stream).keyword;
      if (hit.isEmpty) return;
      spot.reset(stream);
      final display = VoiceGuardService._displayFor(
        hit,
        displayByBufLine,
        activeWords,
      );

      // Diagnostics: how far the trigger stood above the ambient noise
      // floor. This is LOGGED, never used to gate the trigger.
      //
      // An earlier version held "weak" hits for a second confirmation.
      // That was wrong: sherpa-onnx fires once per utterance and the
      // stream is reset on every hit, so a second confirmation within any
      // window could never arrive - a real trigger in a quiet room would
      // have been silently DROPPED. A missed SOS is far worse than a
      // spurious one (a false alarm can be cancelled), so the trigger
      // always fires and the false-alarm rate is controlled where it
      // actually belongs: the trigger threshold, which was measured at
      // 0.10 (see kws_bench.py).
      final double peak = rmsHistory.isEmpty
          ? rms
          : rmsHistory.reduce((a, b) => a > b ? a : b);
      final double floor = noiseFloor < 1e-5 ? 1e-5 : noiseFloor;
      final double snrDb = 20.0 * (math.log(peak / floor) / math.ln10);

      debugPrint('[VoiceGuard] trigger word heard: $display '
          '(snr=${snrDb.toStringAsFixed(1)}dB)');
      unawaited(fireKeyword(display));
    }, onError: (Object e) {
      debugPrint('[VoiceGuard] mic stream error: $e');
      // Visible on-device now (debugPrints don't reach logcat on this ROM).
      // Recovery: a dead stream stops delivering chunks, so the stall
      // watchdog rebuilds the audio path within ~20–30 s.
      unawaited(VoiceGuardService.flog('bg', 'mic stream error: $e'));
      service.invoke(
        VoiceGuardService._errorEvent,
        {'error': 'Microphone stream error: $e'},
      );
    });
      await VoiceGuardService.flog('bg', 'mic loop (re)started');
      return true;
    }

    SosExecutor.bindMicHooks(
      onPause: () async {
        micPausedByExecutor = true;
        await stopMicLoop();
      },
      onResume: () async {
        await startMicLoop();
        micPausedByExecutor = false;
      },
    );
    if (micPausedByExecutor) {
      // A boot raced the SOS executor's native evidence recording, which owns
      // the mic right now. Boot the engine bookkeeping but skip capture — the
      // executor's onResume hook starts the loop when it releases the mic.
      note('Listening soon…');
      await VoiceGuardService.markStage('engine-up');
      await VoiceGuardService.flog('bg', 'ENGINE-UP deferred: executor owns mic');
      engineRunning = true;
      engineUpSinceMs = DateTime.now().millisecondsSinceEpoch;
      lastRefreshMs = engineUpSinceMs;
      engineFailed = false;
      service.invoke(VoiceGuardService._statusEvent, {'running': true});
      return true;
    }
    if (!await startMicLoop()) {
      engineFailed = true;
      return false;
    }

    debugPrint('VoiceGuard KWS engine started, listening');
    note('Listening for "${activeWords.first.toLowerCase()}"');
    await VoiceGuardService.markStage('engine-up');
    await VoiceGuardService.flog('bg', 'ENGINE-UP listening');
    engineRunning = true;
    engineUpSinceMs = DateTime.now().millisecondsSinceEpoch;
    lastRefreshMs = engineUpSinceMs;
    engineFailed = false;
    service.invoke(VoiceGuardService._statusEvent, {'running': true});
    return true;
  } catch (e, s) {
    await VoiceGuardService.flog('bg', 'BG-CATCH: $e');
    developer.log(
      'BG service failed: $e\n$s',
      name: 'VoiceGuard',
      level: 1000,
    );
    debugPrint('VoiceGuard BG service failed: $e\n$s');
    note('Voice guard error — open app for details');
    service.invoke(VoiceGuardService._errorEvent, {'error': '$e'});
    engineRunning = false;
    service.invoke(VoiceGuardService._statusEvent, {'running': false});
    engineFailed = true;
    return false;
  } finally {
    engineBooting = false;
  }
  }

  bool fullTimerOn = false;
  void startFullTimer() {
    if (fullTimerOn) return;
    fullTimerOn = true;
    Timer.periodic(const Duration(seconds: 10), (_) async {
    // Engine claims listening but capture is verifiably dead: either chunks
    // arrive as exact zeros (OS muting) or no chunk ever arrived (permission
    // revoked / dead AudioRecord) — the UI must show degraded, not Listening.
    final bool micDead = diagChunks == 0 &&
        (micEverChunked
            ? micStallRestarts >= 3
            : engineUpSinceMs > 0 &&
                DateTime.now().millisecondsSinceEpoch - engineUpSinceMs >
                    45000);
    service.invoke('heartbeat', {
      'degraded': !micPausedByExecutor &&
          (engineFailed || micZeroBeats >= 3 || micDead),
    });
    // Mic-health telemetry (cheap, 1 line/10s — proved its worth twice).
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final int ageMs = diagLastChunkMs == 0 ? -1 : nowMs - diagLastChunkMs;
    unawaited(VoiceGuardService.flog('bg',
        'mic-health chunks=$diagChunks decoded=$diagDecoded samples=$diagSamples sumSq=$diagSumSq vadSkipped=$vadSkipped lastChunkAgeMs=$ageMs'));
    // Stall watchdog: a live-but-silent stream (zero chunks while listening,
    // never while executor-paused for native recording) gets restarted.
    // Arms only after the stream proved healthy once; capped at 3 restarts
    // per boot to avoid a hot loop on a permanently-dead mic.
    // Zero-energy watchdog: chunks arriving with EXACT-zero energy (digital
    // zeros from a background-muted or stuck AudioRecord) PASS the count
    // check, so they get their own trigger: sustained exact-zero while
    // listening first attempts a re-promote (policy mutes need foreground),
    // then rebuilds the stream (stuck handles need a fresh AudioRecord).
    // Quiet rooms read ~50-300/window, never exact 0.0, so the 1e-9 bound
    // cannot misfire on real silence.
    if (micPausedByExecutor) {
      micSilentBeats = 0;
      micZeroBeats = 0;
    } else if (diagChunks > 0 && diagSumSq <= 1e-9) {
      micSilentBeats = 0;
      micZeroBeats++;
      if (micZeroBeats == 3 || micZeroBeats == 6) {
        try {
          if (service is AndroidServiceInstance) {
            await service.setAsForegroundService();
            await VoiceGuardService.flog('bg', 'zero-energy re-promote attempted');
          }
        } catch (e) {
          await VoiceGuardService.flog('bg', 'zero-energy re-promote failed: $e');
        }
      }
      if (micZeroBeats == 3) {
        // Honest status: 30 s of exact-zero capture while "listening" means
        // the OS is muting this background capture path (observed after a
        // boot-started engine). The heartbeat payload carries degraded=true,
        // so the UI shows "microphone muted" instead of "Listening".
        unawaited(VoiceGuardService.flog(
            'bg', 'mic degraded: 30s of exact-zero capture'));
      }
      if (micZeroBeats >= 6 && micEverChunked && micStallRestarts < 3) {
        micStallRestarts++;
        micZeroBeats = 0;
        micSilentBeats = 0;
        unawaited(bootEngine(force: true));
      }
    } else if (diagChunks > 0) {
      micSilentBeats = 0;
      micZeroBeats = 0;
      micStallRestarts = 0;
    } else {
      micSilentBeats++;
      if (micSilentBeats >= 2 && micEverChunked && micStallRestarts < 3) {
        micStallRestarts++;
        micSilentBeats = 0;
        unawaited(bootEngine(force: true));
      }
    }
    // Periodic KWS session refresh (anti-deafness). The spotter can go
    // silently deaf over a long uptime: healthy chunks with real energy keep
    // arriving, yet no keyword is ever confirmed (observed ≈30 min on this
    // ROM; only an app relaunch restored it). Both watchdogs above check the
    // MIC only, so that state passes them. This paced rebuild runs the same
    // code path as a manual restart and hands the watchdog budgets a fresh
    // allowance (pacing bounds the rate, so no hot loop). Skipped while the
    // executor owns the mic for native SOS recording — the next tick
    // re-checks.
    if (engineRunning && !engineBooting && !micPausedByExecutor) {
      final int anchor = lastRefreshMs > 0 ? lastRefreshMs : engineUpSinceMs;
      final int refreshPeriodMs =
          VoiceGuardService._kwsRefreshPeriod.inMilliseconds;
      if (anchor > 0 && nowMs - anchor >= refreshPeriodMs) {
        micStallRestarts = 0;
        micSilentBeats = 0;
        micZeroBeats = 0;
        lastRefreshMs = nowMs;
        final int uptimeMin =
            engineUpSinceMs == 0 ? -1 : (nowMs - engineUpSinceMs) ~/ 60000;
        unawaited(VoiceGuardService.flog('bg',
            'spotter refresh (periodic): uptime=${uptimeMin}min, rebuilding KWS session'));
        unawaited(bootEngine(force: true, forceReason: 'refresh'));
      }
    }
    diagChunks = 0;
    diagSumSq = 0.0;
    diagSamples = 0;
    diagDecoded = 0;
    vadSkipped = 0;
    });
  }

  service.on('boot_engine').listen((_) async {
    await VoiceGuardService.flog('bg', 'boot_engine requested');
    if (await bootEngine()) {
      standbyHeartbeat?.cancel();
      standbyHeartbeat = null;
      startFullTimer();
    }
  });
  // Standby isolates stop here with handlers live: the engine boots only via
  // an explicit boot_engine invoke (dashboard post-login heal) or a fresh
  // startService() (voice toggle ON from true-off). Keeps the standby
  // contract (no mic capture before the user opts in) while making the heal
  // path real.
  if (!voiceOn) return;
  if (!await bootEngine()) return;
  startFullTimer();
}

class _LifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = VoiceGuardService._appInForeground;
    final foreground = state == AppLifecycleState.resumed;
    VoiceGuardService._appInForeground = foreground;
    VoiceGuardService._service.invoke(
      VoiceGuardService._setForegroundEvent,
      {'foreground': foreground},
    );
    if (foreground && !wasForeground) {
      // App is coming back to the foreground after being backgrounded; fire any
      // SOS trigger that was detected while the main isolate was paused.
      VoiceGuardService._firePendingTriggerIfRecent();
    }
  }
}
