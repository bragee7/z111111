package com.zelda.zelda_guardian

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import java.io.File

/**
 * Background SOS evidence recorder.
 *
 * Primary: CameraX video (back camera, SD, WITH audio) for 30 s — this is
 * what runs when the SOS fires while the app UI is closed, where the
 * Flutter CameraController cannot run (Activity/texture-bound).
 * Fallback: audio-only MediaRecorder file if camera bind fails.
 *
 * Completion contract (FlutterSharedPreferences, flutter.-prefixed keys —
 * same keys the Dart SosExecutor polls):
 *   flutter.zelda_sos_video_path = absolute path (video ok)
 *   flutter.zelda_sos_audio_path = absolute path + flutter.zelda_sos_audio_only=true (fallback)
 *   flutter.zelda_sos_native_done = "done" (presence = finished)
 *
 * Early stop: whoever owns the SOS writes flutter.zelda_sos_native_command
 * = "stop" (cancel path mirrors Dart _doCancel); the service deletes the
 * partial file and exits WITHOUT writing done keys.
 */
class SosRecordingService : Service(), LifecycleOwner {

    companion object {
        private const val TAG = "SosRecording"
        private const val CHANNEL_ID = "zelda_sos_recording"
        private const val NOTIF_ID = 260
        const val ACTION_RECORD = "com.zelda.zelda_guardian.SOS_RECORD"
        const val EXTRA_SECONDS = "seconds"

        private const val PREFS = "FlutterSharedPreferences"
        private const val NATIVE_CMD = "flutter.zelda_sos_native_command"
        private const val NATIVE_DONE = "flutter.zelda_sos_native_done"
        private const val VIDEO_PATH = "flutter.zelda_sos_video_path"
        private const val AUDIO_PATH = "flutter.zelda_sos_audio_path"
        private const val AUDIO_ONLY = "flutter.zelda_sos_audio_only"

        fun start(context: Context, seconds: Int = 30) {
            val intent = Intent(context, SosRecordingService::class.java).apply {
                action = ACTION_RECORD
                putExtra(EXTRA_SECONDS, seconds)
            }
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
                context.stopService(Intent(context, SosRecordingService::class.java))
            } catch (_: Exception) {}
        }
    }

    private val registry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = registry

    private lateinit var prefs: SharedPreferences
    private var worker: HandlerThread? = null
    private var handler: Handler? = null
    private var recording: Recording? = null
    private var audioRecorder: MediaRecorder? = null
    private var outFile: File? = null
    private var done = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        registry.currentState = Lifecycle.State.CREATED
        prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        worker = HandlerThread("sos-recording").apply { start() }
        handler = Handler(worker!!.looper)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != ACTION_RECORD) {
            stopSelf()
            return START_NOT_STICKY
        }
        // Android 14+ (targetSDK 34+): startForeground with a
        // camera/microphone type throws SecurityException when the app is in
        // the background (e.g. power-button SOS with the screen locked). An
        // uncaught throw here kills the whole process — including the Dart BG
        // isolate mid-SOS — so the SOS is never sent. Catch it, report
        // NATIVE_DONE="failed" so the Dart side still sends the SOS (without
        // evidence) instead of dying. See TEST D 2026-10-06.
        try {
            startForeground(NOTIF_ID, buildNotification())
        } catch (e: SecurityException) {
            Log.w(TAG, "startForeground denied from background — failing open so SOS still sends: ${e.message}")
            try {
                if (!::prefs.isInitialized) {
                    prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                }
                prefs.edit().putString(NATIVE_DONE, "failed").apply()
            } catch (_: Exception) {}
            stopSelf()
            return START_NOT_STICKY
        }
        registry.currentState = Lifecycle.State.STARTED
        val seconds = intent.getIntExtra(EXTRA_SECONDS, 30).coerceIn(5, 60)
        handler?.post { runRecording(seconds) }
        // Watch for an early stop (cancel) while recording.
        handler?.post(stopWatcher)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        try {
            recording?.stop()
        } catch (_: Exception) {}
        try {
            audioRecorder?.apply { stop(); release() }
        } catch (_: Exception) {}
        audioRecorder = null
        try {
            registry.currentState = Lifecycle.State.DESTROYED
        } catch (_: Exception) {}
        worker?.quitSafely()
        worker = null
        super.onDestroy()
    }

    private val stopWatcher = object : Runnable {
        override fun run() {
            if (done) return
            val cmd = try {
                prefs.getString(NATIVE_CMD, "") ?: ""
            } catch (_: Exception) { "" }
            if (cmd == "stop") {
                Log.i(TAG, "early stop requested — discarding partial file")
                finish(cancelled = true)
                return
            }
            handler?.postDelayed(this, 500)
        }
    }

    private fun runRecording(seconds: Int) {
        if (stopRequested()) {
            finish(cancelled = true)
            return
        }
        if (!tryVideo(seconds)) {
            Log.w(TAG, "camera bind failed — audio-only fallback")
            runAudioOnly(seconds)
        }
    }

    private fun stopRequested(): Boolean = try {
        prefs.getString(NATIVE_CMD, "") == "stop"
    } catch (_: Exception) { false }

    // ── primary: CameraX video with audio ──

    private fun tryVideo(seconds: Int): Boolean {
        return try {
            val providerFuture = ProcessCameraProvider.getInstance(this)
            val provider = providerFuture.get()
            val selector = CameraSelector.DEFAULT_BACK_CAMERA

            val recorder = Recorder.Builder()
                .setQualitySelector(QualitySelector.from(Quality.SD))
                .build()
            val videoCapture = VideoCapture.withOutput(recorder)

            try {
                provider.unbindAll()
                provider.bindToLifecycle(this as LifecycleOwner, selector, videoCapture)
            } catch (e: Exception) {
                Log.w(TAG, "camera bind failed: ${e.message}")
                return false
            }

            val file = File(filesDir, "sos_evidence_${System.currentTimeMillis()}.mp4")
            outFile = file
            val output = FileOutputOptions.Builder(file).build()

            // Audio on — but never let a mic conflict kill the video: if the
            // audio track fails the file is still valid evidence.
            val rec = videoCapture.output.prepareRecording(this, output)
            recording = try {
                rec.withAudioEnabled().start(ContextCompat.getMainExecutor(this)) { event ->
                    onVideoEvent(event)
                }
            } catch (e: Exception) {
                Log.w(TAG, "video+audio start failed, retry silent: ${e.message}")
                rec.start(ContextCompat.getMainExecutor(this)) { event ->
                    onVideoEvent(event)
                }
            }

            // Hard stop at the budget.
            handler?.postDelayed({
                try {
                    recording?.stop()
                } catch (_: Exception) {}
            }, seconds * 1000L)
            true
        } catch (e: Exception) {
            Log.w(TAG, "tryVideo failed: ${e.message}")
            false
        }
    }

    private fun onVideoEvent(event: VideoRecordEvent) {
        when (event) {
            is VideoRecordEvent.Finalize -> {
                if (done) return
                if (!event.hasError() && (outFile?.exists() == true)) {
                    Log.i(TAG, "video saved: ${outFile!!.absolutePath}")
                    finish(cancelled = false)
                } else {
                    Log.w(TAG, "video finalize error ${event.error} — audio fallback")
                    runAudioOnly(30)
                }
            }
            else -> {}
        }
    }

    // ── fallback: audio-only MediaRecorder ──

    private fun runAudioOnly(seconds: Int) {
        if (done || stopRequested()) {
            finish(cancelled = true)
            return
        }
        try {
            val file = File(filesDir, "sos_evidence_${System.currentTimeMillis()}.m4a")
            outFile = file
            val rec = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(this)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }).apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setOutputFile(file.absolutePath)
                prepare()
                start()
            }
            audioRecorder = rec
            handler?.postDelayed({
                try {
                    rec.stop()
                } catch (_: Exception) {}
                try {
                    rec.release()
                } catch (_: Exception) {}
                audioRecorder = null
                if (done) return@postDelayed
                if (stopRequested() || !file.exists()) {
                    finish(cancelled = true)
                    return@postDelayed
                }
                Log.i(TAG, "audio saved: ${file.absolutePath}")
                reportAudioDone(file)
                finish(cancelled = false, alreadyReported = true)
            }, seconds * 1000L)
        } catch (e: Exception) {
            Log.w(TAG, "audio fallback failed: ${e.message}")
            finish(cancelled = true)
        }
    }

    private fun reportAudioDone(file: File) {
        val editor = prefs.edit()
        editor.putString(AUDIO_PATH, file.absolutePath)
        editor.putBoolean(AUDIO_ONLY, true)
        editor.putString(NATIVE_DONE, "done")
        try {
            editor.apply()
        } catch (_: Exception) {}
    }

    private fun finish(cancelled: Boolean, alreadyReported: Boolean = false) {        if (done) return
        done = true
        handler?.removeCallbacks(stopWatcher)
        if (cancelled) {
            try {
                outFile?.takeIf { it.exists() }?.delete()
            } catch (_: Exception) {}
        } else if (!alreadyReported) {
            try {
                val f = outFile
                if (f != null && f.exists()) {
                    prefs.edit()
                        .putString(VIDEO_PATH, f.absolutePath)
                        .putString(NATIVE_DONE, "done")
                        .apply()
                } else {
                    prefs.edit().putString(NATIVE_DONE, "failed").apply()
                }
            } catch (_: Exception) {}
        }
        stopSelf()
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            nm.getNotificationChannel(CHANNEL_ID) == null
        ) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "ZELDA SOS Recording",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Recording SOS evidence in the background"
                }
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("ZELDA SOS recording")
            .setContentText("Recording emergency evidence…")
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setOngoing(true)
            .build()
    }
}
