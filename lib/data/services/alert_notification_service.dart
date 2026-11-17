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
  static const String _prefShowCallbacksInSummaryKey =
      'alerts_summary_show_callbacks_v1';
  static const String _prefShowCamAgeInSummaryKey =
      'alerts_summary_show_cam_age_v1';
  static const String _prefNotifiedMapKey = 'alerts_notified_keys_v1';
  static const String _prefActiveNotifIdsKey = 'alerts_active_notif_ids_v1';
  static const int _overflowSummaryNotifId = 99000;

  /// Suppresses duplicate popups for the same `(alertType, callId, driverId)`
  /// for the duration of a shift (6 hours) so the same alert is never spammed
  /// every few minutes.
  static const int cooldownMs = 6 * 60 * 60 * 1000; // 6 hours

  bool _notificationsEnabled = true;
  bool get notificationsEnabled => _notificationsEnabled;

  bool _soundEnabled = true;
  bool get soundEnabled => _soundEnabled;

  bool _keepAliveEnabled = true;
  bool get keepAliveEnabled => _keepAliveEnabled;

  bool _showCallbacksInSummary = false;
  bool get showCallbacksInSummary => _showCallbacksInSummary;

  bool _showCameraAgeInSummary = true;
  bool get showCameraAgeInSummary => _showCameraAgeInSummary;

  bool _batteryOptimizationIgnored = false;
  bool get batteryOptimizationIgnored => _batteryOptimizationIgnored;

  /// Maps `alertKey` -> `epochMs` when first notified during the current shift.
  final Map<String, int> _notifiedAlerts = {};

  /// Maps currently active `alertKey` -> deterministic OS `notificationId` so
  /// notifications auto-dismiss as soon as the alert is resolved.
  final Map<String, int> _activeNotificationIdsByKey = {};
  bool _overflowNotificationActive = false;
  bool _initialized = false;

  /// Exposed for testing: currently active non-persistent notification IDs keyed by alert key.
  Map<String, int> get activeNotificationIdsByKey =>
      Map.unmodifiable(_activeNotificationIdsByKey);

  static String _alertKey(DispatchAlert alert) =>
      '${alert.type.code}:${alert.callId}:${alert.driverId}';

  /// Produces a stable notification ID in `10000..89999` (never colliding with
  /// `42000` persistent summary or `99000` overflow notification).
  static int _notificationIdForKey(String key) {
    int hash = 0x811c9dc5;
    for (int i = 0; i < key.length; i++) {
      hash ^= key.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    final id = 10000 + (hash % 80000);
    return id == 42000 ? 42001 : id;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _notificationsEnabled = prefs.getBool(_prefEnabledKey) ?? true;
      _soundEnabled = prefs.getBool(_prefSoundKey) ?? true;
      _keepAliveEnabled = prefs.getBool(_prefKeepAliveKey) ?? true;
      _showCallbacksInSummary =
          prefs.getBool(_prefShowCallbacksInSummaryKey) ?? false;
      _showCameraAgeInSummary =
          prefs.getBool(_prefShowCamAgeInSummaryKey) ?? true;
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
      final savedActive =
          prefs.getStringList(_prefActiveNotifIdsKey) ?? const [];
      for (final entry in savedActive) {
        final idx = entry.lastIndexOf('|');
        if (idx <= 0) continue;
        final key = entry.substring(0, idx);
        final id = int.tryParse(entry.substring(idx + 1));
        if (id != null) {
          _activeNotificationIdsByKey[key] = id;
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
  /// summary of active calls, alerts, optional callbacks count, and optional camera age.
  Future<void> updatePersistentSummary({
    required String title,
    required String body,
    String? collapsedBody,
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
        'collapsedBody': collapsedBody ?? body,
        'body': body,
        'subText': subText,
      });
    } catch (_) {}
  }

  Future<void> setShowCallbacksInSummary(bool enabled) async {
    _showCallbacksInSummary = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefShowCallbacksInSummaryKey, enabled);
    } catch (_) {}
  }

  Future<void> setShowCameraAgeInSummary(bool enabled) async {
    _showCameraAgeInSummary = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefShowCamAgeInSummaryKey, enabled);
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
    } else {
      await _dismissAllActiveAlertNotifications();
    }
  }

  Future<void> setSoundEnabled(bool enabled) async {
    _soundEnabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefSoundKey, enabled);
    } catch (_) {}
  }

  /// Evaluates the latest [alerts] list:
  /// 1. Auto-dismisses any previously posted non-persistent notification whose
  ///    alert is no longer active.
  /// 2. Fires OS notifications only once per `(alertType, callId, driverId)`
  ///    (never repeating every few minutes for the same alert).
  Future<int> processAlerts(List<DispatchAlert> alerts) async {
    if (!_initialized) {
      await initialize();
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final currentKeys = alerts.map(_alertKey).toSet();

    // 1. Auto-dismiss notifications for alerts that have cleared/resolved
    final resolvedKeys = _activeNotificationIdsByKey.keys
        .where((k) => !currentKeys.contains(k))
        .toList(growable: false);
    if (resolvedKeys.isNotEmpty) {
      for (final key in resolvedKeys) {
        final notifId = _activeNotificationIdsByKey.remove(key);
        if (notifId != null) {
          await _cancelPlatformNotification(notifId);
        }
      }
      unawaited(_persistActiveNotificationIds());
    }
    if (_overflowNotificationActive && currentKeys.length <= 2) {
      _overflowNotificationActive = false;
      await _cancelPlatformNotification(_overflowSummaryNotifId);
    }

    // Prune shift-expired deduplication keys ONLY if the alert is not currently active
    _notifiedAlerts.removeWhere(
      (key, ts) => !currentKeys.contains(key) && (nowMs - ts) >= cooldownMs,
    );

    if (!_notificationsEnabled || alerts.isEmpty) {
      return 0;
    }

    final newlyTriggered = <DispatchAlert>[];
    for (final alert in alerts) {
      final key = _alertKey(alert);
      final lastTs = _notifiedAlerts[key];
      if (lastTs == null || (nowMs - lastTs) >= cooldownMs) {
        _notifiedAlerts[key] = nowMs;
        newlyTriggered.add(alert);
      } else {
        // Refresh timestamp while still active so an ongoing alert never expires mid-call
        _notifiedAlerts[key] = nowMs;
      }
    }

    if (newlyTriggered.isEmpty) return 0;
    unawaited(_persistNotifiedKeys());

    // Cap individual popups per poll cycle to avoid flooding if a whole shift loads at once:
    // If <= 3 new alerts, show individual notifications; if > 3, show top 2 + summary notification.
    if (newlyTriggered.length <= 3) {
      for (int i = 0; i < newlyTriggered.length; i++) {
        final a = newlyTriggered[i];
        final key = _alertKey(a);
        final notifId = _notificationIdForKey(key);
        _activeNotificationIdsByKey[key] = notifId;
        final cleanDriver = a.driverName.split('*').first.trim();
        await _dispatchPlatformNotification(
          id: notifId,
          title: 'AAA Alert: ${a.type.label} — $cleanDriver',
          body: 'Call ${a.callId} (${a.workType}): ${a.detail}',
          playSound: _soundEnabled && i == 0,
        );
      }
    } else {
      for (int i = 0; i < 2; i++) {
        final a = newlyTriggered[i];
        final key = _alertKey(a);
        final notifId = _notificationIdForKey(key);
        _activeNotificationIdsByKey[key] = notifId;
        final cleanDriver = a.driverName.split('*').first.trim();
        await _dispatchPlatformNotification(
          id: notifId,
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
      _overflowNotificationActive = true;
      await _dispatchPlatformNotification(
        id: _overflowSummaryNotifId,
        title: '+$moreCount More AAA Dispatch Alerts',
        body: 'Drivers: $names',
        playSound: false,
      );
    }
    unawaited(_persistActiveNotificationIds());

    return newlyTriggered.length;
  }

  Future<void> _dismissAllActiveAlertNotifications() async {
    final ids = _activeNotificationIdsByKey.values.toList(growable: false);
    _activeNotificationIdsByKey.clear();
    for (final id in ids) {
      await _cancelPlatformNotification(id);
    }
    if (_overflowNotificationActive) {
      _overflowNotificationActive = false;
      await _cancelPlatformNotification(_overflowSummaryNotifId);
    }
    unawaited(_persistActiveNotificationIds());
  }

  Future<void> _cancelPlatformNotification(int id) async {
    if (kIsWeb) return;
    try {
      if (Platform.isAndroid) {
        await _androidChannel.invokeMethod<bool>('cancelNotification', {
          'id': id,
        });
      }
    } catch (_) {}
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

  Future<void> _persistActiveNotificationIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _activeNotificationIdsByKey.entries
          .map((e) => '${e.key}|${e.value}')
          .toList(growable: false);
      await prefs.setStringList(_prefActiveNotifIdsKey, list);
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
\$appId = 'com.aaatracker.app';
\$regPath = "HKCU:\\Software\\Classes\\AppUserModelId\\\$appId";
if (-not (Test-Path \$regPath)) {
  New-Item -Path \$regPath -Force | Out-Null;
  New-ItemProperty -Path \$regPath -Name 'DisplayName' -Value 'AAA Tracker' -PropertyType String -Force | Out-Null;
}
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null;
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null;
\$xml = New-Object Windows.Data.Xml.Dom.XmlDocument;
\$xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>$safeTitle</text><text>$safeBody</text></binding></visual></toast>');
\$toast = [Windows.UI.Notifications.ToastNotification]::new(\$xml);
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(\$appId).Show(\$toast);
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
