package com.zelda.zelda_guardian

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import java.util.UUID

/**
 * Single persisted SOS lifecycle contract shared by Dart (SosExecutor) and the
 * native alarm/coordinator. Keys are the existing `FlutterSharedPreferences`
 * entries (with the `flutter.` prefix used by shared_preferences), plus the
 * session fence introduced to make cancellation authoritative.
 *
 * Prefs resolution rules (same as Dart SosLifecycle):
 *  - a non-empty session id is authoritative: cancelled only when it equals
 *    the persisted cancelled-session id;
 *  - legacy snapshots without an id fall back to command/timestamp checks.
 */
object SosSessionStore {
    private const val TAG = "SosSessionStore"
    private const val PREFS = "FlutterSharedPreferences"
    private const val PREFIX = "flutter."

    const val STATE = PREFIX + "zelda_sos_state"
    const val REMAINING = PREFIX + "zelda_sos_remaining"
    const val SOURCE = PREFIX + "zelda_sos_source"
    const val STARTED_AT = PREFIX + "zelda_sos_started_at"
    const val COMMAND = PREFIX + "zelda_sos_command"
    const val CASE_ID = PREFIX + "zelda_sos_case_id"
    const val VIDEO_PATH = PREFIX + "zelda_sos_video_path"
    const val AUDIO_PATH = PREFIX + "zelda_sos_audio_path"
    const val AUDIO_ONLY = PREFIX + "zelda_sos_audio_only"
    const val NATIVE_COMMAND = PREFIX + "zelda_sos_native_command"
    const val NATIVE_DONE = PREFIX + "zelda_sos_native_done"
    const val ALARM_REQUEST = PREFIX + "zelda_sos_alarm_request"
    const val ALARM_HANDLED = PREFIX + "zelda_sos_alarm_handled"
    const val SENDING_AT = PREFIX + "zelda_sos_sending_at"
    const val SESSION_ID = PREFIX + "zelda_sos_session_id"
    const val CANCELLED_SESSION_ID = PREFIX + "zelda_sos_cancelled_session_id"
    const val CANCELLED_AT = PREFIX + "zelda_sos_cancelled_at"
    const val CANCEL_REASON = PREFIX + "zelda_sos_cancel_reason"
    const val PENDING_VOICE = PREFIX + "zelda_pending_sos_trigger"
    const val PENDING_POWER = PREFIX + "zelda_power_sos_trigger"

    private val ACTIVE_STATES = setOf("cancelWindow", "countdown", "recording", "sending")

    fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun currentSession(p: SharedPreferences): String =
        p.getString(SESSION_ID, "")?.trim().orEmpty()

    fun cancelledSession(p: SharedPreferences): String =
        p.getString(CANCELLED_SESSION_ID, "")?.trim().orEmpty()

    fun isActiveState(state: String?): Boolean = ACTIVE_STATES.contains(state?.trim())

    fun isSessionCancelled(p: SharedPreferences): Boolean {
        val session = currentSession(p)
        val cancelled = cancelledSession(p)
        if (session.isNotEmpty()) return cancelled.isNotEmpty() && session == cancelled
        if (p.getString(COMMAND, "")?.trim() == "cancel") return true
        val started = p.getLong(STARTED_AT, 0L)
        val cancelledAt = p.getLong(CANCELLED_AT, 0L)
        return cancelledAt > 0L && (started <= 0L || cancelledAt >= started)
    }

    fun newSessionId(): String =
        "sos_${System.currentTimeMillis()}_${UUID.randomUUID().toString().take(8)}"

    /**
     * Idempotent cancellation commit. Returns true when the session is
     * cancelled (including "already cancelled"), false only when persistence
     * failed so callers can surface a retryable error instead of fake success.
     */
    fun commitCancel(context: Context, reason: String): Boolean {
        return try {
            val p = prefs(context)
            val session = currentSession(p)
            val already = session.isNotEmpty() &&
                session == cancelledSession(p) &&
                !isActiveState(p.getString(STATE, ""))
            val now = System.currentTimeMillis()
            val editor = p.edit()
                .putString(STATE, "listening")
                .putLong(REMAINING, 0L)
                .putString(COMMAND, "")
                .putString(NATIVE_COMMAND, "stop")
                .putLong(ALARM_REQUEST, 0L)
                .putLong(ALARM_HANDLED, 0L)
                .remove(SENDING_AT)
                .remove(NATIVE_DONE)
                .remove(PENDING_VOICE)
                .remove(PENDING_POWER)
            if (session.isNotEmpty()) {
                editor.putString(CANCELLED_SESSION_ID, session)
            }
            if (!already) {
                editor.putLong(CANCELLED_AT, now)
                editor.putString(CANCEL_REASON, reason)
            }
            // Synchronous: native callers gate on this result immediately.
            editor.commit()
            try {
                SosRecordingService.stop(context)
            } catch (_: Exception) {
            }
            Log.i(TAG, "CANCELLED ($reason) session=${session.ifEmpty { "(legacy)" }}")
            true
        } catch (e: Exception) {
            Log.e(TAG, "cancel commit failed: $e")
            false
        }
    }

    /** Drops pending trigger replays without touching the current fence. */
    fun cleanupPending(p: SharedPreferences) {
        p.edit().remove(PENDING_VOICE).remove(PENDING_POWER).apply()
    }
}
