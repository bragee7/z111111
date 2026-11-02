package com.zelda.zelda_guardian

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Counts SCREEN_ON / SCREEN_OFF in a rolling 6s window.
 * 3+ presses => stash a pending SOS trigger in FlutterSharedPreferences
 * (same file Dart shared_preferences reads) + wake the app.
 *
 * Each physical power press yields exactly ONE event (SCREEN_OFF when the
 * screen was on, SCREEN_ON when it was off), so "press power 3 times in
 * 6 seconds" == 3 events in the window.
 */
class PowerPressReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "PowerPress"
        private const val WINDOW_MS = 6000L
        private const val REQUIRED_PRESSES = 3
        const val PREFS_NAME = "FlutterSharedPreferences"
        // Flutter's shared_preferences plugin namespaces every key with the
        // "flutter." prefix inside this file. Native code MUST use the
        // prefixed form or Dart reads null (pending trigger never consumed).
        const val PENDING_KEY = "flutter.zelda_power_sos_trigger"
        const val ENABLED_KEY = "flutter.zelda_power_sos_enabled"
        // Wakes the native SOS coordinator (PowerGuardService poller). The
        // Dart voice engine writes the same key on keyword detection.
        const val ALARM_REQUEST_KEY = "flutter.zelda_sos_alarm_request"
        const val SOURCE_KEY = "flutter.zelda_sos_source"
        private const val ACTION_TRIGGER = "com.zelda.zelda_guardian.POWER_SOS_TRIGGER"

        private val pressTimes = ArrayDeque<Long>()

        @Synchronized
        fun recordPress(context: Context): Boolean {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            if (!prefs.getBoolean(ENABLED_KEY, true)) return false
            val now = System.currentTimeMillis()
            pressTimes.addLast(now)
            while (pressTimes.isNotEmpty() && now - pressTimes.first() > WINDOW_MS) {
                pressTimes.removeFirst()
            }
            Log.d(TAG, "press count in window: ${pressTimes.size}")
            if (pressTimes.size >= REQUIRED_PRESSES) {
                pressTimes.clear()
                return true
            }
            return false
        }

        fun setEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(ENABLED_KEY, enabled).apply()
        }

        fun isEnabled(context: Context): Boolean {
            return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getBoolean(ENABLED_KEY, true)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_SCREEN_ON && action != Intent.ACTION_SCREEN_OFF) return
        try {
            if (recordPress(context)) {
                Log.i(TAG, "3x power press detected -> triggering SOS")
                // Stash pending trigger for Dart to consume on next start.
                context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .edit().putLong(PENDING_KEY, System.currentTimeMillis()).apply()
                // Wake the native SOS coordinator even when every Dart isolate
                // is dead: PowerGuardService polls this key and runs the
                // 5s cancel window + alarm UI natively (no app open needed).
                context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .edit().putLong(ALARM_REQUEST_KEY, System.currentTimeMillis())
                    .putString(SOURCE_KEY, "power-button")
                    .apply()
                // Notify the guard service (foreground) to post the alarm.
                val trigger = Intent(context, PowerGuardService::class.java).apply {
                    this.action = ACTION_TRIGGER
                }
                try {
                    context.startForegroundService(trigger)
                } catch (e: Exception) {
                    Log.w(TAG, "startForegroundService failed: ${e.message}")
                }
                // Bring the app to the foreground so SosController can show the
                // same 5s cancel window.
                val launch = context.packageManager
                    .getLaunchIntentForPackage(context.packageName)?.apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        putExtra("zelda_power_sos", true)
                    }
                try {
                    context.startActivity(launch)
                } catch (e: Exception) {
                    Log.w(TAG, "launch failed: ${e.message}")
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "onReceive failed: ${e.message}")
        }
    }
}
