package com.aaatracker.aaa_tracker_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Foreground service (`dataSync`) that keeps the Dart VM and network sockets alive
 * when the app is out of focus or the screen is off on Android, while displaying
 * a live persistent summary notification.
 */
class TrackerKeepAliveService : Service() {
    companion object {
        const val SUMMARY_CHANNEL_ID = "aaa_tracker_live_summary_v1"
        const val SUMMARY_NOTIFICATION_ID = 42000
        const val ACTION_START_OR_UPDATE = "com.aaatracker.aaa_tracker_app.START_OR_UPDATE"
        const val ACTION_STOP = "com.aaatracker.aaa_tracker_app.STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_COLLAPSED_BODY = "collapsedBody"
        const val EXTRA_BODY = "body"
        const val EXTRA_SUBTEXT = "subText"
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        ensureSummaryChannel()
        acquireLocks()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            releaseLocks()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
            return START_NOT_STICKY
        }

        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "AAA Tracker Live"
        val body = intent?.getStringExtra(EXTRA_BODY) ?: "Monitoring active drivers & fleet safety..."
        val collapsedBody = intent?.getStringExtra(EXTRA_COLLAPSED_BODY)?.takeIf { it.isNotEmpty() } ?: body
        val subText = intent?.getStringExtra(EXTRA_SUBTEXT) ?: ""

        val notification = buildSummaryNotification(title, collapsedBody, body, subText)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    SUMMARY_NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(SUMMARY_NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            // If Android 14+ restricts starting foreground service in a rare state,
            // still post the ongoing notification via NotificationManager.
            try {
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(SUMMARY_NOTIFICATION_ID, notification)
            } catch (_: Exception) {
            }
        }

        acquireLocks()
        return START_STICKY
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureSummaryChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(SUMMARY_CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    SUMMARY_CHANNEL_ID,
                    "AAA Tracker Live Status",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Persistent live summary of active drivers, alerts, and fleet cameras"
                    setShowBadge(false)
                    enableVibration(false)
                    setSound(null, null)
                }
                manager.createNotificationChannel(channel)
            }
        }
    }

    private fun buildSummaryNotification(
        title: String,
        collapsedBody: String,
        body: String,
        subText: String
    ): Notification {
        ensureSummaryChannel()
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingIntent = PendingIntent.getActivity(this, 0, launchIntent, pendingFlags)

        val builder = NotificationCompat.Builder(this, SUMMARY_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(collapsedBody)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(pendingIntent)

        if (subText.isNotEmpty()) {
            builder.setSubText(subText)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    private fun acquireLocks() {
        try {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "AAATracker::BackgroundSyncWakeLock"
                ).apply {
                    setReferenceCounted(false)
                }
            }
            if (wakeLock?.isHeld == false) {
                // Hold partial wake lock for up to 12 hours per shift (renewed on each update)
                wakeLock?.acquire(12 * 60 * 60 * 1000L)
            }
        } catch (_: Exception) {
        }

        try {
            if (wifiLock == null) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val lockMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm.createWifiLock(lockMode, "AAATracker::BackgroundSyncWifiLock").apply {
                    setReferenceCounted(false)
                }
            }
            if (wifiLock?.isHeld == false) {
                wifiLock?.acquire()
            }
        } catch (_: Exception) {
        }
    }

    private fun releaseLocks() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Exception) {
        }
        try {
            if (wifiLock?.isHeld == true) {
                wifiLock?.release()
            }
        } catch (_: Exception) {
        }
    }
}
