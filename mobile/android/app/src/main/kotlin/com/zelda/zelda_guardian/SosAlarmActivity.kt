package com.zelda.zelda_guardian

import android.app.Activity
import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Full-screen SOS cancel UI shown over the home screen and lock screen.
 * Reference: Android Emergency SOS style — title, live 5..1 countdown in a
 * coral ring, large tap-to-cancel button at the bottom. The SOS is ALREADY
 * triggered: there is no "start" action, only cancel.
 *
 * State is owned by whoever runs the SOS (Dart SosExecutor when alive, else
 * the native coordinator in PowerGuardService), mirrored in
 * FlutterSharedPreferences. This activity only DISPLAYS the mirror and
 * writes a cancel command — cancelling works without opening ZELDA.
 */
class SosAlarmActivity : Activity() {

    companion object {
        private const val TAG = "SosAlarm"
        private const val PREFS = "FlutterSharedPreferences"
        private const val STATE = "flutter.zelda_sos_state"
        private const val REMAINING = "flutter.zelda_sos_remaining"
        private const val COMMAND = "flutter.zelda_sos_command"

        @Volatile
        var isShowing = false
            private set

        private fun dp(c: Context, v: Int): Int =
            TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), c.resources.displayMetrics
            ).toInt()
    }

    private lateinit var prefs: SharedPreferences
    private lateinit var countText: TextView
    private lateinit var subtitleText: TextView
    private val ui = Handler(Looper.getMainLooper())
    private var finished = false
    // Sticky display (flicker fix): last time an ACTIVE sos state was seen,
    // and the last countdown number shown. This screen only closes on user
    // cancel or when the SOS has been over (inactive state) for the full
    // grace window — transient prefs gaps must never unmount it.
    private var lastActiveTs = System.currentTimeMillis()
    private var lastCount = "5"
    // One-shot guard: the window-over branch must finish exactly once.
    // Without this the 250 ms refresher can call finish() again after a
    // config change / slow destroy — each extra finish() is one more
    // `f}}}` record in the task (the duplicate `auto-dismissing` logs).
    // Display only — SOS state untouched.
    private var windowOver = false
    // One-shot guard: a second tap while the cancel command is being written
    // is swallowed, so exactly one cancel request can ever be issued here.
    private var cancelRequested = false
    private lateinit var cancelButton: TextView

    /** Inactive states tolerated this long before closing. */
    private val INACTIVE_GRACE_MS = 8000L

    private val refresher = object : Runnable {
        override fun run() {
            if (finished) return
            refresh()
            ui.postDelayed(this, 250)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        isShowing = true
        prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        // Show over the lock screen and turn the screen on.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // System-SOS style handoff: only a NON-secure (swipe/none) keyguard
        // is dismissed behind this screen. A secure lock keeps its credential
        // gate — showWhenLocked above is what lets this UI display over the
        // keyguard without ever prompting for the pattern/PIN. Display only.
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val km = getSystemService(KeyguardManager::class.java)
                if (km != null && km.isKeyguardLocked && !km.isKeyguardSecure) {
                    km.requestDismissKeyguard(this, null)
                }
            }
        } catch (_: Exception) {}

        setContentView(buildUi())
        ui.post(refresher)
    }

    override fun onResume() {
        super.onResume()
        // Re-request the non-secure keyguard handoff (onCreate may have run
        // while the screen was off). Same gating as onCreate — a secure lock
        // is never dismissed from here. Display only.
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val km = getSystemService(KeyguardManager::class.java)
                if (km != null && km.isKeyguardLocked && !km.isKeyguardSecure) {
                    km.requestDismissKeyguard(this, null)
                }
            }
        } catch (_: Exception) {}
    }

    override fun onDestroy() {
        finished = true
        ui.removeCallbacks(refresher)
        isShowing = false
        super.onDestroy()
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onBackPressed() {
        // The countdown must stay visible until the user cancels or it
        // elapses: an accidental back gesture must not dismiss this UI
        // (finishing without cancelling would hide the window while the
        // SOS keeps running).
    }

    // ── UI (built programmatically to keep the screen in one file) ──

    private fun buildUi(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
            val p = dp(this@SosAlarmActivity, 24)
            setPadding(p, dp(this@SosAlarmActivity, 48), p, dp(this@SosAlarmActivity, 32))
        }

        // Title row: "Zelda Emergency SOS" + decorative gear.
        val titleRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val title = TextView(this).apply {
            text = "SOS Alert Active"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 30f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val gear = TextView(this).apply {
            text = "\u2699"
            setTextColor(Color.parseColor("#9AA0A6"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 30f)
        }
        titleRow.addView(title)
        titleRow.addView(gear)
        root.addView(titleRow)

        val tagline = TextView(this).apply {
            text = "Your emergency alert has been triggered."
            setTextColor(Color.parseColor("#9AA0A6"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            setPadding(0, dp(this@SosAlarmActivity, 8), 0, 0)
        }
        root.addView(tagline)

        val will = TextView(this).apply {
            text = "Your phone will:"
            setTextColor(Color.parseColor("#9AA0A6"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 19f)
            setPadding(0, dp(this@SosAlarmActivity, 16), 0, 0)
        }
        root.addView(will)

        val actionRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(this@SosAlarmActivity, 12), 0, 0)
        }
        val check = TextView(this).apply {
            text = "\u2713   "
            setTextColor(Color.parseColor("#34A853"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val action = TextView(this).apply {
            text = "Send SOS + record evidence"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 21f)
        }
        actionRow.addView(check)
        actionRow.addView(action)
        root.addView(actionRow)

        // Center: coral ring with the live countdown number.
        val center = FrameLayout(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f
            ).apply { gravity = Gravity.CENTER }
        }
        val ringSize = dp(this@SosAlarmActivity, 260)
        val ringBg = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.TRANSPARENT)
            setStroke(dp(this@SosAlarmActivity, 9), Color.parseColor("#F0716A"))
        }
        val ring = FrameLayout(this).apply {
            layoutParams = FrameLayout.LayoutParams(ringSize, ringSize, Gravity.CENTER)
            background = ringBg
        }
        countText = TextView(this).apply {
            text = "5"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 96f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            gravity = Gravity.CENTER
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        }
        ring.addView(countText)
        center.addView(ring)
        root.addView(center)

        subtitleText = TextView(this).apply {
            text = "SOS will be sent automatically — cancel to stop"
            setTextColor(Color.parseColor("#9AA0A6"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(this@SosAlarmActivity, 20))
        }
        root.addView(subtitleText)

        // Bottom: large tap-to-cancel button. A single tap cancels via the
        // shared command=cancel path; repeated taps are swallowed while the
        // request is in flight (cancelRequested).
        root.addView(buildCancelButton())
        return root
    }

    private fun buildCancelButton(): View {
        val h = dp(this@SosAlarmActivity, 80)
        val bg = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = h / 2f
            setColor(Color.parseColor("#C62828"))
        }
        cancelButton = TextView(this).apply {
            text = "CANCEL SOS"
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            background = bg
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, h
            )
            isClickable = true
            isFocusable = true
            contentDescription = "Cancel SOS. Activate to cancel the active emergency alert."
            setOnClickListener { onCancelTapped() }
        }
        return cancelButton
    }

    /**
     * Single tap cancels — no swipe. After the first tap the button disables
     * itself and shows CANCELLING… so duplicate taps can never write a second
     * cancel command.
     */
    private fun onCancelTapped() {
        if (finished || cancelRequested) return
        cancelRequested = true
        cancelButton.text = "CANCELLING…"
        cancelButton.isEnabled = false
        cancelButton.alpha = 0.7f
        cancelSos()
    }

    // ── state sync ──

    private fun refresh() {
        // A confirmed cancellation is terminal for this activity, even if a
        // stale FSI/refresh callback tries to keep the alert on screen.
        if (SosSessionStore.isSessionCancelled(prefs)) {
            isShowing = false
            finish()
            return
        }
        val state = try {
            prefs.getString(STATE, "idle") ?: "idle"
        } catch (_: Exception) { "idle" }
        // remaining is written as Long by Flutter's SharedPreferences plugin
        // (Dart setInt → putLong) but as Int by the native drive flow
        // (putInt). getInt throws ClassCastException on a Long entry, which
        // used to freeze the digit at its initial "5" — read type-tolerantly.
        val remaining = try {
            when (val v = prefs.all[REMAINING]) {
                is Number -> v.toInt()
                is String -> v.toString().toIntOrNull() ?: 0
                else -> 0
            }
        } catch (_: Exception) { 0 }

        when (state) {
            "cancelWindow", "countdown" -> {
                lastActiveTs = System.currentTimeMillis()
                // Transient pref gaps keep the last number; only a CHANGED
                // number touches the TextView (no redundant layout passes =
                // no flicker while the digit ticks).
                val shown =
                    if (remaining >= 1) remaining.toString() else lastCount
                if (shown != lastCount) {
                    lastCount = shown
                    countText.text = shown
                }
            }
            "recording", "sending", "sent" -> {
                // Cancel window is over — the SOS (recording/upload) continues on
                // its own in the service/executor. This Activity is only the
                // cancel-window display, so dismiss WITHOUT writing any cancel
                // command and WITHOUT stopping anything. One-shot: the 250 ms
                // refresher must not re-finish after a config change / slow
                // destroy (each extra finish() is a duplicate task record).
                if (!windowOver) {
                    windowOver = true
                    isShowing = false
                    finish()
                }
            }
            else -> {
                // Idle/listening/transient: close only once the SOS is
                // genuinely over (inactive for the full grace window).
                // Finishing on any gap caused the flicker loop
                // (finish → dashboard revealed → guarded relaunch).
                if (System.currentTimeMillis() - lastActiveTs > INACTIVE_GRACE_MS) {
                    finish()
                }
            }
        }
    }

    private fun cancelSos() {
        if (finished) return
        // Same centralized native commit the coordinator/notification use:
        // clears the mirror, pending triggers, alarm handshake and recorder,
        // and stamps the session fence so nothing can relaunch this alert.
        SosSessionStore.commitCancel(this, "alarm-activity")
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(PowerGuardService.ALARM_NOTIF_ID)
        } catch (_: Exception) {}
        finish()
    }
}
