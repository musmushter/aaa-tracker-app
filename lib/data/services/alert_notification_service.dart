import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/models/dispatch_alert.dart';

/// Cross-platform system notification & sound alert dispatcher for AAA Dispatch alerts.
///
/// Supports:
/// - **Android:** Native `NotificationCompat` channel (`IMPORTANCE_HIGH`) via
///   `MainActivity` `MethodChannel` + Android 13+ runtime permission request.
/// - **Linux:** `notify-send` (`--urgency=critical`) / `gdbus` org.freedesktop.Notifications
///   + `paplay` / `pw-play` system alert sound.
/// - **Windows:** PowerShell `Windows.UI.Notifications.ToastNotificationManager`
///   toast + `[System.Media.SystemSounds]::Exclamation.Play()`.
/// - **macOS:** `osascript -e 'display notification ...'` + `afplay`.
class AlertNotificationService {
  AlertNotificationService();

  static const String _channelName =
      'com.aaatracker.aaa_tracker_app/notifications';
  static const MethodChannel _androidChannel = MethodChannel(_channelName);

  static const String _prefEnabledKey = 'alerts_notifications_enabled_v1';
  static const String _prefSoundKey = 'alerts_sound_enabled_v1';
  static const String _prefKeepAliveKey = 'android_keep_alive_enabled_v1';
  static const String _prefNotifiedMapKey = 'alerts_notified_keys_v1';

  /// Minimum cooldown before re-notifying the exact same `(alertType, callId, driverId)`.
  static const int cooldownMs = 15 * 60 * 1000; // 15 minutes

  bool _notificationsEnabled = true;
  bool get notificationsEnabled => _notificationsEnabled;

  bool _soundEnabled = true;
  bool get soundEnabled => _soundEnabled;

  bool _keepAliveEnabled = true;
  bool get keepAliveEnabled => _keepAliveEnabled;

  bool _batteryOptimizationIgnored = false;
  bool get batteryOptimizationIgnored => _batteryOptimizationIgnored;

  /// Maps `alertKey` -> `epochMs` when last notified.
  final Map<String, int> _notifiedAlerts = {};
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _notificationsEnabled = prefs.getBool(_prefEnabledKey) ?? true;
      _soundEnabled = prefs.getBool(_prefSoundKey) ?? true;
      _keepAliveEnabled = prefs.getBool(_prefKeepAliveKey) ?? true;
      final savedList = prefs.getStringList(_prefNotifiedMapKey) ?? const [];
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      for (final entry in savedList) {
        final idx = entry.lastIndexOf('|');
        if (idx <= 0) continue;
        final key = entry.substring(0, idx);
        final ts = int.tryParse(entry.substring(idx + 1));
        if (ts != null && (nowMs - ts) < cooldownMs) {
          _notifiedAlerts[key] = ts;
        }
      }
    } catch (_) {}

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      if (_notificationsEnabled || _keepAliveEnabled) {
        unawaited(requestPermissionIfNeeded());
      }
      unawaited(refreshBatteryOptimizationStatus());
      if (_keepAliveEnabled) {
        unawaited(
          updatePersistentSummary(
            title: 'AAA Tracker Live',
            body: 'Starting background sync...',
          ),
        );
      }
    }
  }

  Future<bool> refreshBatteryOptimizationStatus() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      final res = await _androidChannel.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
      _batteryOptimizationIgnored = res ?? false;
      return _batteryOptimizationIgnored;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestIgnoreBatteryOptimizations() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _androidChannel.invokeMethod<bool>(
        'requestIgnoreBatteryOptimizations',
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      await refreshBatteryOptimizationStatus();
    } catch (_) {}
  }

  Future<void> setKeepAliveEnabled(bool enabled) async {
    _keepAliveEnabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKeepAliveKey, enabled);
    } catch (_) {}
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      if (enabled) {
        await requestPermissionIfNeeded();
        await _androidChannel.invokeMethod<bool>('startOrUpdateKeepAlive', {
          'title': 'AAA Tracker Live',
          'body': 'Background sync active.',
          'subText': '',
        });
      } else {
        await _androidChannel.invokeMethod<bool>('stopKeepAlive');
      }
    } catch (_) {}
  }

  /// Updates the persistent Android Foreground Service notification with a live
  /// summary of active calls, alerts, callbacks, and fleet cameras.
  Future<void> updatePersistentSummary({
    required String title,
    required String body,
    String subText = '',
  }) async {
    if (!_keepAliveEnabled ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _androidChannel.invokeMethod<bool>('startOrUpdateKeepAlive', {
        'title': title,
        'body': body,
        'subText': subText,
      });
    } catch (_) {}
  }

  Future<void> requestPermissionIfNeeded() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _androidChannel.invokeMethod<bool>('requestPermission');
    } catch (_) {}
  }

  Future<void> setNotificationsEnabled(bool enabled) async {
    _notificationsEnabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefEnabledKey, enabled);
    } catch (_) {}
    if (enabled) {
      await requestPermissionIfNeeded();
    }
  }

  Future<void> setSoundEnabled(bool enabled) async {
    _soundEnabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefSoundKey, enabled);
    } catch (_) {}
  }

  /// Evaluates the latest [alerts] list, firing OS notifications only for newly
  /// triggered alerts (or alerts whose 15-minute cooldown has elapsed).
  Future<int> processAlerts(List<DispatchAlert> alerts) async {
    if (!_initialized) {
      await initialize();
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _notifiedAlerts.removeWhere((_, ts) => (nowMs - ts) >= cooldownMs);

    if (!_notificationsEnabled || alerts.isEmpty) {
      return 0;
    }

    final newlyTriggered = <DispatchAlert>[];
    for (final alert in alerts) {
      final key = '${alert.type.code}:${alert.callId}:${alert.driverId}';
      final lastTs = _notifiedAlerts[key];
      if (lastTs == null || (nowMs - lastTs) >= cooldownMs) {
        _notifiedAlerts[key] = nowMs;
        newlyTriggered.add(alert);
      }
    }

    if (newlyTriggered.isEmpty) return 0;
    unawaited(_persistNotifiedKeys());

    // Cap individual popups per poll cycle to avoid flooding if a whole shift loads at once:
    // If <= 3 new alerts, show individual notifications; if > 3, show top 2 + summary notification.
    if (newlyTriggered.length <= 3) {
      for (int i = 0; i < newlyTriggered.length; i++) {
        final a = newlyTriggered[i];
        final cleanDriver = a.driverName.split('*').first.trim();
        await _dispatchPlatformNotification(
          id: a.hashCode.abs() % 100000 + i,
          title: 'AAA Alert: ${a.type.label} — $cleanDriver',
          body: 'Call ${a.callId} (${a.workType}): ${a.detail}',
          playSound: _soundEnabled && i == 0,
        );
      }
    } else {
      for (int i = 0; i < 2; i++) {
        final a = newlyTriggered[i];
        final cleanDriver = a.driverName.split('*').first.trim();
        await _dispatchPlatformNotification(
          id: a.hashCode.abs() % 100000 + i,
          title: 'AAA Alert: ${a.type.label} — $cleanDriver',
          body: 'Call ${a.callId} (${a.workType}): ${a.detail}',
          playSound: _soundEnabled && i == 0,
        );
      }
      final moreCount = newlyTriggered.length - 2;
      final names = newlyTriggered
          .skip(2)
          .take(4)
          .map((a) => a.driverName.split('*').first.trim())
          .join(', ');
      await _dispatchPlatformNotification(
        id: 99000 + moreCount,
        title: '+$moreCount More AAA Dispatch Alerts',
        body: 'Drivers: $names',
        playSound: false,
      );
    }

    return newlyTriggered.length;
  }

  /// Sends a test notification on the current platform so the user can verify
  /// OS permissions and sound output immediately.
  Future<void> sendTestNotification() async {
    await requestPermissionIfNeeded();
    await _dispatchPlatformNotification(
      id: 88888,
      title: 'AAA Tracker — Alert Notifications Active',
      body:
          'You will be notified when a driver is Dispatch Overdue, Standing Still >10m, or ETA Late.',
      playSound: _soundEnabled,
    );
  }

  Future<void> _persistNotifiedKeys() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _notifiedAlerts.entries
          .map((e) => '${e.key}|${e.value}')
          .toList(growable: false);
      await prefs.setStringList(_prefNotifiedMapKey, list);
    } catch (_) {}
  }

  Future<void> _dispatchPlatformNotification({
    required int id,
    required String title,
    required String body,
    required bool playSound,
  }) async {
    if (kIsWeb) return;
    try {
      if (Platform.isAndroid) {
        await _androidChannel.invokeMethod<bool>('showNotification', {
          'id': id,
          'title': title,
          'body': body,
          'playSound': playSound,
        });
        return;
      }

      if (Platform.isLinux) {
        await _sendLinuxNotification(
          title: title,
          body: body,
          playSound: playSound,
        );
        return;
      }

      if (Platform.isWindows) {
        await _sendWindowsNotification(
          title: title,
          body: body,
          playSound: playSound,
        );
        return;
      }

      if (Platform.isMacOS) {
        await _sendMacOsNotification(
          title: title,
          body: body,
          playSound: playSound,
        );
        return;
      }
    } catch (_) {}
  }

  Future<void> _sendLinuxNotification({
    required String title,
    required String body,
    required bool playSound,
  }) async {
    try {
      final res = await Process.run('notify-send', [
        '--app-name=AAA Tracker',
        '--urgency=critical',
        '--icon=dialog-warning',
        title,
        body,
      ]);
      if (res.exitCode != 0) {
        await Process.run('gdbus', [
          'call',
          '--session',
          '--dest=org.freedesktop.Notifications',
          '--object-path=/org/freedesktop/Notifications',
          '--method=org.freedesktop.Notifications.Notify',
          'AAA Tracker',
          '0',
          'dialog-warning',
          title,
          body,
          '[]',
          '{"urgency": <byte 2>}',
          '8000',
        ]);
      }
    } catch (_) {}

    if (playSound) {
      unawaited(_playLinuxAlertSound());
    }
  }

  Future<void> _playLinuxAlertSound() async {
    const soundCandidates = [
      '/usr/share/sounds/freedesktop/stereo/dialog-warning.oga',
      '/usr/share/sounds/freedesktop/stereo/message-new-instant.oga',
      '/usr/share/sounds/freedesktop/stereo/bell.oga',
    ];
    for (final path in soundCandidates) {
      if (File(path).existsSync()) {
        try {
          final res = await Process.run('paplay', [path]);
          if (res.exitCode == 0) return;
        } catch (_) {}
        try {
          final res = await Process.run('pw-play', [path]);
          if (res.exitCode == 0) return;
        } catch (_) {}
      }
    }
    try {
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {}
  }

  Future<void> _sendWindowsNotification({
    required String title,
    required String body,
    required bool playSound,
  }) async {
    final safeTitle = title
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll("'", "''");
    final safeBody = body
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll("'", "''");
    final soundLine = playSound
        ? '[System.Media.SystemSounds]::Exclamation.Play();'
        : '';
    final psScript = '''
\$ErrorActionPreference = 'SilentlyContinue';
$soundLine
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null;
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null;
\$xml = New-Object Windows.Data.Xml.Dom.XmlDocument;
\$xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>$safeTitle</text><text>$safeBody</text></binding></visual></toast>');
\$toast = [Windows.UI.Notifications.ToastNotification]::new(\$xml);
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('AAA Dispatch Tracker').Show(\$toast);
''';
    try {
      await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', psScript],
        runInShell: false,
      );
    } catch (_) {}
  }

  Future<void> _sendMacOsNotification({
    required String title,
    required String body,
    required bool playSound,
  }) async {
    final safeTitle = title.replaceAll('"', r'\"');
    final safeBody = body.replaceAll('"', r'\"');
    final soundClause = playSound ? ' sound name "Ping"' : '';
    try {
      await Process.run('osascript', [
        '-e',
        'display notification "$safeBody" with title "$safeTitle"$soundClause',
      ]);
    } catch (_) {}
  }
}
