package com.example.poc_call

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

object CallNotifications {
    const val IDLE_CH = "poc_call_idle2"    // importance MIN + hidden on lock screen
    const val ACTIVE_CH = "poc_call_active" // shown during a call
    const val INCOMING_CH = "poc_call_incoming"
    const val SERVICE_ID = 1
    const val INCOMING_ID = 2

    fun ensureChannels(ctx: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.deleteNotificationChannel("poc_call_service") // old channels
        nm.deleteNotificationChannel("poc_call_idle")
        nm.createNotificationChannel(
            NotificationChannel(IDLE_CH, "Background connection", NotificationManager.IMPORTANCE_MIN).apply {
                description = "Silent: keeps the app connected so you can receive calls"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
            })
        nm.createNotificationChannel(
            NotificationChannel(ACTIVE_CH, "Ongoing call", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while you are in a call"
                setShowBadge(false)
            })
        nm.createNotificationChannel(
            NotificationChannel(INCOMING_CH, "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Alerts for incoming calls"
                setSound(null, null) // ringtone is played by the app itself
                enableVibration(true)
            })
    }

    private fun openApp(ctx: Context, incoming: Boolean): PendingIntent {
        val i = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("incoming", incoming)
        }
        return PendingIntent.getActivity(
            ctx, if (incoming) 1 else 0, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    fun service(ctx: Context, text: String, inCall: Boolean = false): Notification =
        NotificationCompat.Builder(ctx, if (inCall) ACTIVE_CH else IDLE_CH)
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setContentTitle(if (inCall) "Ongoing call" else "In-App Call")
            .setContentText(text)
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .setPriority(if (inCall) NotificationCompat.PRIORITY_LOW else NotificationCompat.PRIORITY_MIN)
            .setVisibility(if (inCall) NotificationCompat.VISIBILITY_PUBLIC else NotificationCompat.VISIBILITY_SECRET)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(openApp(ctx, false))
            .build()

    fun incoming(ctx: Context, caller: String): Notification =
        NotificationCompat.Builder(ctx, INCOMING_CH)
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setContentTitle("Incoming call")
            .setContentText(caller)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(true)
            .setTimeoutAfter(45000)
            .setFullScreenIntent(openApp(ctx, true), true)
            .setContentIntent(openApp(ctx, true))
            .build()
}

// Foreground service: keeps the process (and the app's signaling connection) alive in the background.
class CallService : Service() {
    private var wake: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra("text") ?: "Connected · ready for calls"
        val inCall = intent?.getBooleanExtra("inCall", false) ?: false
        CallNotifications.ensureChannels(this)
        val n = CallNotifications.service(this, text, inCall)
        if (!startFg(n, inCall) && !startFg(n, false)) {
            stopSelf()
            return START_NOT_STICKY
        }
        setWake(inCall)
        // NOT sticky: if the system kills the process the app is no longer connected,
        // so we must not restart a notification that claims otherwise.
        return START_NOT_STICKY
    }

    private fun startFg(n: Notification, inCall: Boolean): Boolean = try {
        val id = CallNotifications.SERVICE_ID
        when {
            Build.VERSION.SDK_INT >= 34 -> startForeground(
                id, n,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                    (if (inCall) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0))
            Build.VERSION.SDK_INT >= 30 -> startForeground(
                id, n, if (inCall) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0)
            Build.VERSION.SDK_INT >= 29 -> startForeground(id, n, 0)
            else -> startForeground(id, n)
        }
        true
    } catch (e: Exception) {
        false
    }

    // Keep the CPU awake only while a call is active.
    private fun setWake(on: Boolean) {
        try {
            if (on) {
                if (wake == null) {
                    val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                    wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "poc_call:call").apply {
                        setReferenceCounted(false)
                        acquire(4 * 60 * 60 * 1000L)
                    }
                }
            } else {
                wake?.release()
                wake = null
            }
        } catch (_: Exception) {}
    }

    // App swiped away from recents: the Flutter engine is gone, so stop claiming we're connected.
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        setWake(false)
        super.onDestroy()
    }
}
