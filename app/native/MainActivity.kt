package com.example.poc_call

import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Native call tones: system ringback (caller) and the phone's default ringtone (callee).
class MainActivity : FlutterActivity() {
    private var tone: ToneGenerator? = null
    private var ringtone: Ringtone? = null

    private fun stopAll() {
        try { tone?.stopTone(); tone?.release() } catch (_: Exception) {}
        tone = null
        try { ringtone?.stop() } catch (_: Exception) {}
        ringtone = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupUpdateChannel(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "poc_call/tones")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "startRingback" -> {
                            stopAll()
                            tone = ToneGenerator(AudioManager.STREAM_VOICE_CALL, 100)
                            tone?.startTone(ToneGenerator.TONE_SUP_RINGTONE)
                            result.success(null)
                        }
                        "startRing" -> {
                            stopAll()
                            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                            val r = RingtoneManager.getRingtone(applicationContext, uri)
                            r.audioAttributes = AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                .build()
                            if (Build.VERSION.SDK_INT >= 28) r.isLooping = true
                            r.play()
                            ringtone = r
                            result.success(null)
                        }
                        "stop" -> { stopAll(); result.success(null) }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("TONE", e.toString(), null)
                }
            }
    }

    private fun setupUpdateChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "poc_call/update")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "cacheDir" -> result.success(cacheDir.absolutePath)
                        "installApk" -> {
                            val path = call.argument<String>("path")!!
                            if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                                // User must allow "install unknown apps" for this app once.
                                startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName")))
                                result.success("needs_permission")
                            } else {
                                val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", File(path))
                                val i = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, "application/vnd.android.package-archive")
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(i)
                                result.success("started")
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("UPDATE", e.toString(), null)
                }
            }
    }

    override fun onDestroy() {
        stopAll()
        super.onDestroy()
    }
}
