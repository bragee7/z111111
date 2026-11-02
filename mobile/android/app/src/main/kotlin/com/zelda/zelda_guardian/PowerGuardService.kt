package com.zelda.zelda_guardian

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import id.flutter.flutter_background_service.BackgroundService

/**
 * Lightweight always-on foreground service that owns the SCREEN_ON/OFF
 * receiver. This is what keeps 4x-power-press working when the app is
 * swiped away / fully killed: the service is START_STICKY with
 * stopWithTask=false so the OS restarts it.
 */
class PowerGuardService : Service() {

    companion object {
        private const val TAG = "PowerGuard"
        private const val CHANNEL_ID = "zelda_power_guard"
        private const val NOTIF_ID = 258
        const val ACTION_TRIGGER = "com.zelda.zelda_guardian.POWER_SOS_TRIGGER"
        const val ALARM_NOTIF_ID = 259
        // Heads-up/lock-screen Cancel button action. Writes the IDENTICAL
        // command the SosAlarmActivity Cancel pill writes; honored through
        // the shared cancel path. Display plumbing only.
        private const val ACTION_CANCEL_ALARM = "com.zelda.zelda_guardian.SOS_ALARM_CANCEL"

        fun start(context: Context) {
            val intent = Intent(context, PowerGuardService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.w(TAG, "start failed: ${e.message}")
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, PowerGuardService::class.java))
            } catch (_: Exception) {}
        }
    }

    private var receiver: BroadcastReceiver? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        registerPowerReceiver()
        startCoordinator()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIF_ID, buildNotification())
        // The power-press receiver arrives with ACTION_TRIGGER — post the
        // cancel alarm once (the duplicate literal check that used to
        // double-post here is gone).
        if (intent?.action == ACTION_TRIGGER) {
            postAlarmNotification()
        }
        if (intent?.action == ACTION_CANCEL_ALARM) {
            handleAlarmCancel()
        }
        return START_STICKY
    }

    // Lock-screen / heads-up Cancel button. Commits the SAME authoritative
    // cancellation as the SosAlarmActivity button: state + session fence +
    // pending triggers + native recording, idempotently. Also withdraws the
    // alarm notification.
    private fun handleAlarmCancel() {
        try {
            SosSessionStore.commitCancel(this, "notification-action")
            nativeActive = false
            pendingAlarmTs = 0L
            Log.i(TAG, "alarm Cancel action tapped — cancellation committed")
        } catch (e: Exception) {
            Log.w(TAG, "alarm cancel commit failed: ${e.message}")
        }
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .cancel(ALARM_NOTIF_ID)
        } catch (_: Exception) {}
    }

    private fun alarmCancelPi(): PendingIntent {
        val cancel = Intent(this, PowerGuardService::class.java).apply {
            action = ACTION_CANCEL_ALARM
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(this, 3, cancel, flags)
        } else {
            @Suppress("DEPRECATION")
            PendingIntent.getService(this, 3, cancel, flags)
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiped away: restart so the guard keeps running while killed.
        val restart = Intent(applicationContext, PowerGuardService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(restart)
            } else {
                startService(restart)
            }
        } catch (e: Exception) {
            Log.w(TAG, "restart failed: ${e.message}")
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        stopCoordinator()
        try {
            receiver?.let { unregisterReceiver(it) }
        } catch (_: Exception) {}
        receiver = null
        super.onDestroy()
    }

    private fun registerPowerReceiver() {
        if (receiver != null) return
        receiver = PowerPressReceiver()
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        try {
            // API 33+ throws SecurityException without an explicit exported
            // flag. System broadcasts must use NOT_EXPORTED.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(receiver, filter)
            }
            Log.i(TAG, "power receiver registered")
        } catch (e: Exception) {
            Log.w(TAG, "register failed: ${e.message}")
            receiver = null
        }
    }

    // ── native SOS coordinator ──────────────────────────────
    // Owns the emergency flow ONLY when no Dart executor is alive (every
    // Flutter isolate dead). When Dart is alive it already claimed the SOS
    // in prefs — here we only surface the SosAlarmActivity display.
    // Prefs contract (FlutterSharedPreferences, flutter.-prefixed):
    //   state/remaining/source/started_at/command/case/video/audio/audioOnly,
    //   native_command (stop/start_recording), native_done, alarm_request/handled.
    private var coordThread: HandlerThread? = null
    private var coordHandler: Handler? = null

    // Native-owned flow runtime.
    private var nativeActive = false
    private var nativePhase = ""
    private var nativeRemaining = 0
    private var lastTickMs = 0L
    private var pendingAlarmTs = 0L
    private var dartRecordingStarted = false
    // Last launchAlarmUi() call (launch debounce, see launchAlarmUi).
    private var lastAlarmUiLaunchMs = 0L

    // Last voice-engine supervisor check (see ensureVoiceEngineRunning).
    private var lastVoiceCheckMs = 0L

    private fun sosPrefs() =
        getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

    /**
     * Voice-engine supervisor. The FMBS BackgroundService has no durable
     * self-restart (its respawn watchdog fires once ~5 s after each
     * start/destroy and never re-arms), so after a raw process kill the
     * voice listener stays down until the app is opened. PowerGuardService
     * is START_STICKY and does come back — so whenever it is alive it
     * revives the voice engine itself. Pref-gated on the user's voice SOS
     * setting so a manual disable stays disabled; the plugin side dedupes
     * ("Service already running") when it is already up.
     */
    private fun ensureVoiceEngineRunning() {
        try {
            val voiceOn = sosPrefs()
                .getBoolean("flutter.zelda_voice_guard_enabled", false)
            if (!voiceOn) return
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            // Own-app services only on API 26+ — exactly what we need here.
            val running = am.getRunningServices(64).any {
                it.service.className ==
                    "id.flutter.flutter_background_service.BackgroundService"
            }
            if (running) return
            Log.i(TAG, "voice engine not running — starting BackgroundService")
            val intent = Intent(this, BackgroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (e: Exception) {
            Log.w(TAG, "voice engine start failed: ${e.message}")
        }
    }

    private fun startCoordinator() {
        if (coordThread != null) return
        coordThread = HandlerThread("sos-coordinator").apply { start() }
        coordHandler = Handler(coordThread!!.looper)
        coordHandler?.post(coordinatorTick)
        Log.i(TAG, "SOS coordinator started")
    }

    private fun stopCoordinator() {
        coordHandler?.removeCallbacks(coordinatorTick)
        coordHandler = null
        coordThread?.quitSafely()
        coordThread = null
        nativeActive = false
    }

    private val coordinatorTick = object : Runnable {
        override fun run() {
            try {
                tickOnce()
            } catch (e: Exception) {
                Log.w(TAG, "coordinator tick failed: ${e.message}")
            }
            coordHandler?.postDelayed(this, 500)
        }
    }

    private fun tickOnce() {
        val prefs = sosPrefs()
        val now = System.currentTimeMillis()

        // Cancellation is authoritative and is consumed before anything else:
        // a cancel command left by the alarm activity/notification must commit
        // even when no Dart executor is alive to process it.
        val command = try {
            prefs.getString(SosSessionStore.COMMAND, "")?.trim() ?: ""
        } catch (_: Exception) { "" }
        if (command == "cancel") {
            SosSessionStore.commitCancel(this, "coordinator cancel")
            nativeActive = false
            pendingAlarmTs = 0L
            return
        }
        val cancelled = SosSessionStore.isSessionCancelled(prefs)

        // 0. Voice-engine supervisor: if the user enabled voice SOS and the
        // FMBS BackgroundService is missing (LMK kill, crash, OEM cleanup),
        // revive it. Idempotent + throttled; pref-gated; plugin dedupes.
        if (now - lastVoiceCheckMs > 30000) {
            lastVoiceCheckMs = now
            ensureVoiceEngineRunning()
        }

        // 1. New alarm request (voice keyword or power 3x while Dart dead).
        val alarmTs = try {
            prefs.getLong(SosSessionStore.ALARM_REQUEST, 0)
        } catch (_: Exception) { 0 }
        val handled = try {
            prefs.getLong(SosSessionStore.ALARM_HANDLED, 0)
        } catch (_: Exception) { 0 }
        val cancelledAt = try {
            prefs.getLong(SosSessionStore.CANCELLED_AT, 0L)
        } catch (_: Exception) { 0L }
        // A new press/voice alarm after a cancel (ts > cancelled_at) is a
        // genuinely NEW request and must still fire; only requests that
        // predate the cancel are replays of the cancelled session.
        val alarmReplay = cancelled && alarmTs > 0 && alarmTs <= cancelledAt
        if (!alarmReplay && alarmTs > handled && now - alarmTs < 60000) {
            try {
                prefs.edit().putLong(SosSessionStore.ALARM_HANDLED, alarmTs).apply()
            } catch (_: Exception) {}
            pendingAlarmTs = alarmTs
            if (!isAppForeground()) launchAlarmUi()
        }

        val state = try {
            prefs.getString(SosSessionStore.STATE, "") ?: ""
        } catch (_: Exception) { "" }
        val startedAt = try {
            prefs.getLong(SosSessionStore.STARTED_AT, 0)
        } catch (_: Exception) { 0 }
        val dartOwns = state in setOf("cancelWindow", "countdown", "recording", "sending") &&
            now - startedAt < 180000

        // A cancelled session with a still-active mirror is stale by
        // definition: reconcile it to listening and never re-present the UI.
        if (cancelled && SosSessionStore.isActiveState(state)) {
            SosSessionStore.commitCancel(this, "coordinator reconcile")
            nativeActive = false
            pendingAlarmTs = 0L
            return
        }

        // 2. Dart-owned flow asking for native recording (app-recording no-show).
        if (!nativeActive && !cancelled) {
            val cmd = try {
                prefs.getString("flutter.zelda_sos_native_command", "") ?: ""
            } catch (_: Exception) { "" }
            if (cmd == "start_recording" && !dartRecordingStarted) {
                dartRecordingStarted = true
                SosRecordingService.start(this, 30)
            }
            if (cmd != "start_recording") dartRecordingStarted = false
        }

        // 3. Display: cancel window active but alarm UI not up and app not
        // open. Only the window states launch the UI — once recording starts
        // the window is over and the Activity dismisses itself, so it must
        // NOT be relaunched (that was a relaunch loop).
        if (dartOwns && !nativeActive) {
            // Dart owns this SOS; alarm consumed.
            pendingAlarmTs = 0L
            // Display: an ALARM REQUESTED but Dart already owned the flow
            // before the coordinator consumed the request — the UI may never
            // have been shown, so launch it on window states. No auto-dismiss
            // race: the Activity dismisses itself once recording starts, and
            // the window-states gate below prevents any relaunch loop.
            // Pure display — SOS state untouched.
            if (!cancelled && state in setOf("cancelWindow", "countdown") &&
                !SosAlarmActivity.isShowing && !isAppForeground()) launchAlarmUi()
            return
        }

        // 4. Claim a native-owned flow after the grace window (Dart never came).
        if (!nativeActive && !dartOwns) {
            val cancelledAt = try {
                prefs.getLong(SosSessionStore.CANCELLED_AT, 0L)
            } catch (_: Exception) { 0L }
            // A pending press that predates the cancel is a replay, not a new
            // SOS; a press AFTER the cancel is deliberate and still claims.
            val replay = cancelled && pendingAlarmTs > 0 && pendingAlarmTs <= cancelledAt
            if (replay) {
                pendingAlarmTs = 0L
            } else if (pendingAlarmTs > 0 && now - pendingAlarmTs > 3000 &&
                now - pendingAlarmTs < 60000 && !isAppForeground()
            ) {
                claimNativeFlow(prefs)
                // Claimed (or Dart took it meanwhile) — never re-claim.
                pendingAlarmTs = 0L
            }
            return
        }

        // 5. Drive the native-owned flow (or shut it down if cancelled).
        if (nativeActive) {
            if (cancelled) {
                cancelNativeFlow(prefs, "cancelled session")
            } else {
                driveNativeFlow(prefs, now)
            }
        }
    }

    private fun isAppForeground(): Boolean {
        return try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val procs = am.runningAppProcesses ?: return false
            procs.any { it.processName == packageName &&
                it.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND }
        } catch (_: Exception) { false }
    }

    private fun launchAlarmUi() {
        // Cancellation fence: never present the alert for a cancelled session,
        // even if a stale tick/FSI post is still in flight.
        val guardPrefs = sosPrefs()
        val guardCommand = try {
            guardPrefs.getString(SosSessionStore.COMMAND, "")?.trim() ?: ""
        } catch (_: Exception) { "" }
        if (guardCommand == "cancel" || SosSessionStore.isSessionCancelled(guardPrefs)) {
            Log.i(TAG, "alarm UI suppressed (session cancelled)")
            return
        }
        // Launch debounce: the 500 ms coordinator can tick twice before the
        // launched Activity's onCreate sets isShowing=true (~200-500 ms
        // inflation). Without this, tick N launches task A and tick N+1 sees
        // !isShowing and launches task B — the duplicate-task records
        // (#1358/#1359) and the doubled auto-dismiss log lines. A showing
        // Activity mirrors live prefs via refresh(), so it never needs a
        // relaunch; the only gap this debounce must cover is inflation.
        // 3 s is far below any genuine re-request interval. Display only.
        val nowMs = System.currentTimeMillis()
        if (nowMs - lastAlarmUiLaunchMs < 3000) {
            Log.i(TAG, "alarm UI launch debounced (already launched ${nowMs - lastAlarmUiLaunchMs} ms ago)")
            return
        }
        // Already up (an earlier FSI/launch won the race): re-posting the FSI
        // while the Activity shows re-fires the full-screen launch, which is
        // exactly the visible flash. A showing Activity mirrors live prefs
        // itself, so it never needs a re-post. Display only.
        if (SosAlarmActivity.isShowing) {
            Log.i(TAG, "alarm UI already showing — skipping re-post")
            return
        }
        lastAlarmUiLaunchMs = nowMs
        // Full-screen intent: the one mechanism allowed to appear over the
        // home/lock screen from the background.
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            nm.getNotificationChannel("zelda_voice_protection") == null
        ) {
            nm.createNotificationChannel(
                NotificationChannel(
                    "zelda_voice_protection",
                    "ZELDA Voice Protection",
                    NotificationManager.IMPORTANCE_HIGH
                )
            )
        }
        val alarm = Intent(this, SosAlarmActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val pi = PendingIntent.getActivity(
            this, 2, alarm,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notif = NotificationCompat.Builder(this, "zelda_voice_protection")
            .setContentTitle("\uD83D\uDEA8 ZELDA SOS TRIGGERED")
            .setContentText("Tap Cancel SOS — recording starts automatically…")
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setFullScreenIntent(pi, true)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Cancel SOS",
                alarmCancelPi()
            )
            .setAutoCancel(true)
            .build()
        try {
            nm.notify(ALARM_NOTIF_ID, notif)
        } catch (e: Exception) {
            Log.w(TAG, "alarm FSI failed: ${e.message}")
        }
        // Fallback for ROMs that withhold the FSI activity while the screen
        // is off/locked (verified MIUI behavior): ONE delayed direct start on
        // the coordinator thread — skipped when the FSI already brought the
        // Activity up, and skipped when the flow was cancelled meanwhile.
        // Replaces the old unconditional second launch (start flash +
        // duplicate task record). SYSTEM_ALERT_WINDOW provides the
        // background-activity-start exemption this needs. Display only.
        coordHandler?.postDelayed({
            try {
                val p = sosPrefs()
                val st = try {
                    p.getString(SosSessionStore.STATE, "") ?: ""
                } catch (_: Exception) { "" }
                val cmd = try {
                    p.getString(SosSessionStore.COMMAND, "")?.trim() ?: ""
                } catch (_: Exception) { "" }
                if (!SosAlarmActivity.isShowing &&
                    (st == "cancelWindow" || st == "countdown") &&
                    cmd != "cancel" &&
                    !SosSessionStore.isSessionCancelled(p)
                ) {
                    try {
                        val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                        @Suppress("DEPRECATION")
                        pm.newWakeLock(
                            android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP or
                                android.os.PowerManager.SCREEN_BRIGHT_WAKE_LOCK,
                            "zelda:sos-alarm-wake"
                        ).apply { acquire(30000) }
                    } catch (_: Exception) {}
                    startActivity(alarm)
                    Log.i(TAG, "alarm activity direct-started (FSI fallback)")
                }
            } catch (e: Exception) {
                Log.w(TAG, "alarm direct start blocked: ${e.message}")
            }
        }, 1200)
    }

    private fun claimNativeFlow(prefs: android.content.SharedPreferences) {
        // A cancel that arrived before the claim always wins.
        val claimCommand = try {
            prefs.getString(SosSessionStore.COMMAND, "")?.trim() ?: ""
        } catch (_: Exception) { "" }
        if (claimCommand == "cancel") {
            Log.i(TAG, "native claim suppressed (cancel)")
            return
        }
        // Re-check under the same rules (avoid double-claim with Dart).
        val now = System.currentTimeMillis()
        val state = try {
            prefs.getString("flutter.zelda_sos_state", "") ?: ""
        } catch (_: Exception) { "" }
        val startedAt = try {
            prefs.getLong("flutter.zelda_sos_started_at", 0)
        } catch (_: Exception) { 0 }
        if (state in setOf("cancelWindow", "countdown", "recording", "sending") &&
            now - startedAt < 180000
        ) {
            return // Dart claimed it after all.
        }
        val source = try {
            prefs.getString("flutter.zelda_sos_source", "") ?: ""
        } catch (_: Exception) { "" }
        nativeActive = true
        nativePhase = "countdown"
        nativeRemaining = 5
        lastTickMs = now
        try {
            prefs.edit()
                .putString("flutter.zelda_sos_state", nativePhase)
                .putInt("flutter.zelda_sos_remaining", nativeRemaining)
                .putString("flutter.zelda_sos_source",
                    source.ifEmpty { "power-button" })
                .putLong("flutter.zelda_sos_started_at", now)
                .putString("flutter.zelda_sos_command", "")
                .remove("flutter.zelda_sos_case_id")
                .remove("flutter.zelda_sos_video_path")
                .remove("flutter.zelda_sos_audio_path")
                .putBoolean("flutter.zelda_sos_audio_only", false)
                .remove("flutter.zelda_sos_native_done")
                .putString(SosSessionStore.SESSION_ID, SosSessionStore.newSessionId())
                .putString(SosSessionStore.NATIVE_COMMAND, "")
                .putLong(SosSessionStore.ALARM_HANDLED, 0L)
                .remove(SosSessionStore.PENDING_VOICE)
                .remove(SosSessionStore.PENDING_POWER)
                .apply()
        } catch (_: Exception) {}
        Log.i(TAG, "native SOS flow claimed (Dart dead)")
        if (!SosAlarmActivity.isShowing && !isAppForeground()) launchAlarmUi()
    }

    private fun driveNativeFlow(prefs: android.content.SharedPreferences, now: Long) {
        // Cancel lands via prefs (alarm activity or a later Dart boot).
        val cmd = try {
            prefs.getString("flutter.zelda_sos_command", "") ?: ""
        } catch (_: Exception) { "" }
        if (cmd.trim() == "cancel") {
            cancelNativeFlow(prefs, "alarm-activity cancel")
            return
        }
        // A persisted cancellation fence (native or Dart) always wins.
        if (SosSessionStore.isSessionCancelled(prefs)) {
            cancelNativeFlow(prefs, "cancelled session")
            return
        }
        // A live Dart executor re-claiming mid-flow: stand down, it owns send.
        val state = try {
            prefs.getString("flutter.zelda_sos_state", "") ?: ""
        } catch (_: Exception) { "" }
        if (state == "sending" || state == "sent") {
            nativeActive = false // Dart took over the tail; display follows mirror.
            return
        }
        if (state == "listening" || state == "idle") {
            nativeActive = false // Cancelled/completed elsewhere.
            return
        }

        if (nativePhase == "recording") {
            // Recording service reports via native_done; keep watching cancel.
            val done = try {
                prefs.contains("flutter.zelda_sos_native_done")
            } catch (_: Exception) { false }
            if (done) {
                // Evidence secured. Send/upload needs the auth token, which
                // only Dart can read — park here; the Dart executor (BG or
                // app-open pickup) completes the chain from these prefs.
                Log.i(TAG, "native recording done — awaiting Dart send")
                nativeActive = false
            }
            return
        }

        if (now - lastTickMs < 1000) return
        lastTickMs = now
        nativeRemaining -= 1
        if (nativeRemaining > 0) {
            try {
                prefs.edit()
                    .putInt("flutter.zelda_sos_remaining", nativeRemaining)
                    .putLong("flutter.zelda_sos_started_at", now)
                    .apply()
            } catch (_: Exception) {}
            return
        }
        // Single 5s countdown elapsed → record natively (CameraX, audio
        // fallback). No second phase.
        nativePhase = "recording"
        try {
            prefs.edit()
                .putString("flutter.zelda_sos_state", "recording")
                .putInt("flutter.zelda_sos_remaining", 30)
                .apply()
        } catch (_: Exception) {}
        SosRecordingService.start(this, 30)
    }

    private fun cancelNativeFlow(prefs: android.content.SharedPreferences, reason: String) {
        nativeActive = false
        // Centralized native commit: clears the mirror, pending triggers,
        // alarm handshake and recorder, and stamps the session fence so no
        // tick can relaunch the alert for this session.
        SosSessionStore.commitCancel(this, reason)
        Log.i(TAG, "native SOS CANCELLED ($reason) session=${SosSessionStore.currentSession(prefs)}")
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "ZELDA Power-button Guard",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Keeps 3x power-press SOS active even when the app is closed"
                }
            )
        }
    }

    private fun buildNotification(): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("ZELDA SOS guard active")
            .setContentText("Press power 3x in 6s to send SOS")
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentIntent(launch)
            .setOngoing(true)
            .build()
    }

    private fun postAlarmNotification() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            nm.getNotificationChannel("zelda_voice_protection") == null
        ) {
            nm.createNotificationChannel(
                NotificationChannel(
                    "zelda_voice_protection",
                    "ZELDA Voice Protection",
                    NotificationManager.IMPORTANCE_HIGH,
                )
            )
        }
        val launch = Intent(this, SosAlarmActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val pi = PendingIntent.getActivity(
            this, 1, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notif = NotificationCompat.Builder(this, "zelda_voice_protection")
            .setContentTitle("\uD83D\uDEA8 ZELDA SOS TRIGGERED")
            .setContentText("Power pressed 3x. Opening app to send SOS...")
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setFullScreenIntent(pi, true)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Cancel SOS",
                alarmCancelPi()
            )
            .setAutoCancel(true)
            .build()
        try {
            nm.notify(ALARM_NOTIF_ID, notif)
        } catch (e: Exception) {
            Log.w(TAG, "alarm notify failed: ${e.message}")
        }
    }
}
