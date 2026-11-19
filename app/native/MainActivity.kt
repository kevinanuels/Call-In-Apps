package com.example.poc_call

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.PowerManager
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
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
    private var pendingNotifPerm: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    // Opened from the "Incoming call" notification: show over the lock screen and wake the screen.
    private fun handleIntent(i: Intent?) {
        if (i?.getBooleanExtra("incoming", false) == true && Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
    }

    override fun onStop() {
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(false)
            setTurnScreenOn(false)
        }
        super.onStop()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 77) {
            pendingNotifPerm?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
            pendingNotifPerm = null
        }
    }

    private fun setupBackgroundChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "poc_call/background")
            .setMethodCallHandler { call, result ->
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                try {
                    when (call.method) {
                        "startService" -> {
                            val text = call.argument<String>("text") ?: "Connected · ready for calls"
                            val inCall = call.argument<Boolean>("inCall") ?: false
                            try {
                                ContextCompat.startForegroundService(this,
                                    Intent(this, CallService::class.java).putExtra("text", text).putExtra("inCall", inCall))
                                result.success("started")
                            } catch (e: Exception) {
                                // Not allowed from background: at least refresh the text.
                                CallNotifications.ensureChannels(this)
                                nm.notify(CallNotifications.SERVICE_ID, CallNotifications.service(this, text))
                                result.success("fallback")
                            }
                        }
                        "updateText" -> {
                            CallNotifications.ensureChannels(this)
                            nm.notify(CallNotifications.SERVICE_ID,
                                CallNotifications.service(this, call.argument<String>("text") ?: ""))
                            result.success(null)
                        }
                        "stopService" -> {
                            stopService(Intent(this, CallService::class.java))
                            nm.cancel(CallNotifications.SERVICE_ID)
                            nm.cancel(CallNotifications.INCOMING_ID)
                            result.success(null)
                        }
                        "showIncoming" -> {
                            CallNotifications.ensureChannels(this)
                            nm.notify(CallNotifications.INCOMING_ID,
                                CallNotifications.incoming(this, call.argument<String>("caller") ?: ""))
                            result.success(null)
                        }
                        "cancelIncoming" -> { nm.cancel(CallNotifications.INCOMING_ID); result.success(null) }
                        "requestNotifPermission" -> {
                            if (Build.VERSION.SDK_INT >= 33 &&
                                ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                                != PackageManager.PERMISSION_GRANTED) {
                                pendingNotifPerm = result
                                ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 77)
                            } else result.success(true)
                        }
                        "status" -> {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            result.success(mapOf(
                                "notifications" to NotificationManagerCompat.from(this).areNotificationsEnabled(),
                                "battery" to pm.isIgnoringBatteryOptimizations(packageName),
                                "fullScreen" to (if (Build.VERSION.SDK_INT >= 34) nm.canUseFullScreenIntent() else true)))
                        }
                        "openBatterySettings" -> {
                            startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName")))
                            result.success(null)
                        }
                        "openFullScreenSettings" -> {
                            if (Build.VERSION.SDK_INT >= 34)
                                startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                    Uri.parse("package:$packageName")))
                            result.success(null)
                        }
                        "openNotificationSettings" -> {
                            startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                            result.success(null)
                        }
                        "getFlag" -> result.success(
                            getSharedPreferences("poc_call", Context.MODE_PRIVATE)
                                .getBoolean(call.argument<String>("key"), false))
                        "setFlag" -> {
                            getSharedPreferences("poc_call", Context.MODE_PRIVATE).edit()
                                .putBoolean(call.argument<String>("key"), call.argument<Boolean>("value") ?: true).apply()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("BG", e.toString(), null)
                }
            }
    }

    private fun stopAll() {
        try { tone?.stopTone(); tone?.release() } catch (_: Exception) {}
        tone = null
        try { ringtone?.stop() } catch (_: Exception) {}
        ringtone = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupUpdateChannel(flutterEngine)
        setupBackgroundChannel(flutterEngine)
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
