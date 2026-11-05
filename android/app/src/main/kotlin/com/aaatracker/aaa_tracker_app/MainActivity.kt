package com.aaatracker.aaa_tracker_app

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL_NAME = "com.aaatracker.aaa_tracker_app/notifications"
        private const val NOTIF_CHANNEL_ID = "aaa_dispatch_alerts_v1"
        private const val PERMISSION_REQUEST_CODE = 4201
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ensureNotificationChannel()

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> {
                    requestNotificationPermissionIfNeeded()
                    result.success(true)
                }
                "showNotification" -> {
                    val id = call.argument<Int>("id") ?: (System.currentTimeMillis() % 100000).toInt()
                    val title = call.argument<String>("title") ?: "AAA Dispatch Alert"
                    val body = call.argument<String>("body") ?: ""
                    val playSound = call.argument<Boolean>("playSound") ?: true
                    showNativeNotification(id, title, body, playSound)
                    result.success(true)
                }
                "cancelNotification" -> {
                    val id = call.argument<Int>("id")
                    if (id != null && id != TrackerKeepAliveService.SUMMARY_NOTIFICATION_ID) {
                        NotificationManagerCompat.from(this).cancel(id)
                    }
                    result.success(true)
                }
                "startOrUpdateKeepAlive" -> {
                    val title = call.argument<String>("title") ?: "AAA Tracker Live"
                    val body = call.argument<String>("body") ?: "Monitoring active calls & fleet safety..."
                    val collapsedBody = call.argument<String>("collapsedBody") ?: body
                    val subText = call.argument<String>("subText") ?: ""
                    startOrUpdateForegroundService(title, collapsedBody, body, subText)
                    result.success(true)
                }
                "stopKeepAlive" -> {
                    stopForegroundService()
                    result.success(true)
                }
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "requestIgnoreBatteryOptimizations" -> {
                    requestIgnoreBatteryOptimizations()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startOrUpdateForegroundService(
        title: String,
        collapsedBody: String,
        body: String,
        subText: String
    ) {
        try {
            val serviceIntent = Intent(this, TrackerKeepAliveService::class.java).apply {
                action = TrackerKeepAliveService.ACTION_START_OR_UPDATE
                putExtra(TrackerKeepAliveService.EXTRA_TITLE, title)
                putExtra(TrackerKeepAliveService.EXTRA_COLLAPSED_BODY, collapsedBody)
                putExtra(TrackerKeepAliveService.EXTRA_BODY, body)
                putExtra(TrackerKeepAliveService.EXTRA_SUBTEXT, subText)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ContextCompat.startForegroundService(this, serviceIntent)
            } else {
                startService(serviceIntent)
            }
        } catch (_: Exception) {
        }
    }

    private fun stopForegroundService() {
        try {
            val stopIntent = Intent(this, TrackerKeepAliveService::class.java).apply {
                action = TrackerKeepAliveService.ACTION_STOP
            }
            startService(stopIntent)
        } catch (_: Exception) {
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            return pm.isIgnoringBatteryOptimizations(packageName)
        }
        return true
    }

    @SuppressLint("BatteryLife")
    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                try {
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                    startActivity(intent)
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val existing = manager.getNotificationChannel(NOTIF_CHANNEL_ID)
            if (existing == null) {
                val channel = NotificationChannel(
                    NOTIF_CHANNEL_ID,
                    "AAA Dispatch Alerts",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "High-priority alerts for overdue dispatches, standstill trucks, and expired ETAs"
                    enableVibration(true)
                }
                manager.createNotificationChannel(channel)
            }
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    PERMISSION_REQUEST_CODE
                )
            }
        }
    }

    private fun showNativeNotification(id: Int, title: String, body: String, playSound: Boolean) {
        ensureNotificationChannel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                requestNotificationPermissionIfNeeded()
                return
            }
        }

        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntentFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingIntent = PendingIntent.getActivity(this, id, launchIntent, pendingIntentFlags)

        val builder = NotificationCompat.Builder(this, NOTIF_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)

        if (playSound) {
            val defaultSound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            builder.setSound(defaultSound)
        } else {
            builder.setSilent(true)
        }

        try {
            NotificationManagerCompat.from(this).notify(id, builder.build())
        } catch (_: SecurityException) {
        }
    }
}
