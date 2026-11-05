import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../data/repositories/fsl_repository.dart';
import '../../../../data/repositories/motive_repository.dart';
import '../../../../data/services/alert_notification_service.dart';
import '../../../../data/services/auth_session_service.dart';
import '../../../../domain/models/cleared_call.dart';
import '../../../../domain/models/dispatch_alert.dart';
import '../../../../domain/models/dispatch_row.dart';
import '../../../../domain/models/motive_vehicle.dart';
import '../../../../domain/use_cases/driver_truck_linker.dart';
import '../../../../domain/use_cases/fsl_time_utils.dart';

/// Coordinates unified state across FSL Dispatch Tracker and Motive Safety Console,
/// running automatic multi-signal Driver ↔ Truck linking whenever either updates.
class AppShellViewModel extends ChangeNotifier {
  AppShellViewModel({
    required this._authService,
    required this._fslRepository,
    required this._motiveRepository,
    AlertNotificationService? notificationService,
  }) : _notificationService =
           notificationService ?? AlertNotificationService();

  static const String _prefAutoRefreshCamMin = 'safety_auto_refresh_minutes_v1';

  final AuthSessionService _authService;
  final FslRepository _fslRepository;
  final MotiveRepository _motiveRepository;
  final AlertNotificationService _notificationService;

  AuthSessionService get authService => _authService;
  AlertNotificationService get notificationService => _notificationService;

  /// Dedicated lightweight notifier for the 1-second clock & auto-refresh countdown
  /// so ticking the clock never rebuilds the entire application tree or camera grid.
  final ValueNotifier<int> clockTickNotifier = ValueNotifier<int>(0);

  /// Tracks the number of cameras currently matching the active filters on the
  /// Safety Console tab so the tab badge displays the filtered count.
  final ValueNotifier<int> filteredCameraCountNotifier = ValueNotifier<int>(0);
  bool _isDisposed = false;

  int _selectedTabIndex = 0;
  int get selectedTabIndex => _selectedTabIndex;

  bool _isFslLoading = false;
  bool get isFslLoading => _isFslLoading;

  bool _isMotiveLoading = false;
  bool get isMotiveLoading => _isMotiveLoading;

  bool _isBatchRefreshingCameras = false;
  bool get isBatchRefreshingCameras => _isBatchRefreshingCameras;

  /// Automatic camera refresh interval in minutes (`0` = Off).
  int _cameraAutoRefreshMinutes = 0;
  int get cameraAutoRefreshMinutes => _cameraAutoRefreshMinutes;

  /// Epoch milliseconds when the next automatic camera refresh will run (`null` when Off).
  int? _nextAutoRefreshEpochMs;
  int? get nextAutoRefreshEpochMs => _nextAutoRefreshEpochMs;

  /// Epoch milliseconds when a camera snapshot was last refreshed.
  int? _lastCameraRefreshEpochMs;
  int? get lastCameraRefreshEpochMs => _lastCameraRefreshEpochMs;

  /// Human-readable relative time since the last camera update (e.g., `Just now`, `4m ago`, `Never`).
  String get cameraLastUpdateAgeText {
    final ts = _lastCameraRefreshEpochMs;
    if (ts == null || ts <= 0) return 'Never';
    final diffSec =
        ((DateTime.now().millisecondsSinceEpoch - ts) / 1000).floor();
    if (diffSec < 60) return 'Just now';
    final mins = diffSec ~/ 60;
    if (mins < 60) return '${mins}m ago';
    final hrs = mins ~/ 60;
    final remMins = mins % 60;
    return remMins > 0 ? '${hrs}h ${remMins}m ago' : '${hrs}h ago';
  }

  /// Formatted countdown string until the next automatic camera refresh (e.g. `14:32`),
  /// or `null` when auto-refresh is turned off.
  String? get autoRefreshCountdownText {
    if (_cameraAutoRefreshMinutes <= 0 || _nextAutoRefreshEpochMs == null) {
      return null;
    }
    final remainingSec =
        ((_nextAutoRefreshEpochMs! - DateTime.now().millisecondsSinceEpoch) /
                1000)
            .ceil()
            .clamp(0, 86400);
    final mins = (remainingSec ~/ 60).toString().padLeft(2, '0');
    final secs = (remainingSec % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  /// Live clock string synchronized to the active account's timezone/location
  /// (e.g. `Central 3:45 PM`).
  String get accountClockText => FslTimeUtils.formatAccountClock();

  String _statusBannerText = 'Ready. Configure sessions or sync data.';
  String get statusBannerText => _statusBannerText;

  String? _lastFslError;
  String? get lastFslError => _lastFslError;

  String? _lastFslUpdatedLabel;
  String? get lastFslUpdatedLabel => _lastFslUpdatedLabel;

  List<DispatchRow> _dispatchRows = const [];
  List<DispatchRow> get dispatchRows => _dispatchRows;

  List<DispatchAlert> _dispatchAlerts = const [];
  List<DispatchAlert> get dispatchAlerts => _dispatchAlerts;

  List<ClearedCall> get clearedCalls => _fslRepository.clearedCalls;

  List<MotiveVehicle> _motiveVehicles = const [];
  List<MotiveVehicle> get motiveVehicles => _motiveVehicles;

  /// Optional vehicle ID focused when jumping from a Dispatch row to its linked truck.
  String? _focusedMotiveVehicleId;
  String? get focusedMotiveVehicleId => _focusedMotiveVehicleId;

  Timer? _fslPollTimer;
  Timer? _motivePollTimer;
  Timer? _cameraAutoRefreshTimer;
  Timer? _clockTickTimer;
  bool _isEnrichingBacklog = false;

  /// Current filtered vehicles from the Safety Console tab used as targets for auto-refresh.
  List<MotiveVehicle>? _autoRefreshTargetVehicles;

  /// Tracks alert keys (`type:saId:resourceId` -> epochMs) that have already triggered
  /// an automatic camera refresh so we refresh immediately on new alerts without spamming.
  final Map<String, int> _autoRefreshedAlertKeys = {};
  final Set<String> _inFlightAlertCameraVehicleIds = {};
  bool _isPumpingAlertCameras = false;

  bool get alertsNotificationsEnabled =>
      _notificationService.notificationsEnabled;
  bool get alertsSoundEnabled => _notificationService.soundEnabled;
  bool get androidKeepAliveEnabled => _notificationService.keepAliveEnabled;
  bool get showCallbacksInSummary =>
      _notificationService.showCallbacksInSummary;
  bool get showCameraAgeInSummary =>
      _notificationService.showCameraAgeInSummary;
  bool get batteryOptimizationIgnored =>
      _notificationService.batteryOptimizationIgnored;

  Future<void> setAlertsNotificationsEnabled(bool enabled) async {
    await _notificationService.setNotificationsEnabled(enabled);
    _statusBannerText = enabled
        ? 'Alert notifications enabled.'
        : 'Alert notifications muted.';
    notifyListeners();
  }

  Future<void> setAlertsSoundEnabled(bool enabled) async {
    await _notificationService.setSoundEnabled(enabled);
    _statusBannerText = enabled
        ? 'Alert notification sound enabled.'
        : 'Alert notification sound muted.';
    notifyListeners();
  }

  Future<void> setAndroidKeepAliveEnabled(bool enabled) async {
    await _notificationService.setKeepAliveEnabled(enabled);
    if (enabled) {
      _updatePersistentLiveSummary();
    }
    _statusBannerText = enabled
        ? 'Android background keep-alive & persistent summary enabled.'
        : 'Android background keep-alive stopped.';
    notifyListeners();
  }

  Future<void> setShowCallbacksInSummary(bool enabled) async {
    await _notificationService.setShowCallbacksInSummary(enabled);
    _updatePersistentLiveSummary();
    _statusBannerText = enabled
        ? 'Showing unchecked callbacks count in persistent notification.'
        : 'Hidden callbacks count from persistent notification.';
    notifyListeners();
  }

  Future<void> setShowCameraAgeInSummary(bool enabled) async {
    await _notificationService.setShowCameraAgeInSummary(enabled);
    _updatePersistentLiveSummary();
    _statusBannerText = enabled
        ? 'Showing camera update age in persistent notification.'
        : 'Hidden camera update age from persistent notification.';
    notifyListeners();
  }

  Future<void> requestUnrestrictedAndroidBattery() async {
    await _notificationService.requestIgnoreBatteryOptimizations();
    _statusBannerText = _notificationService.batteryOptimizationIgnored
        ? 'Unrestricted battery mode enabled for AAA Tracker.'
        : 'Requested unrestricted battery access.';
    notifyListeners();
  }

  Future<void> sendTestAlertNotification() async {
    await _notificationService.sendTestNotification();
    _statusBannerText = 'Sent test alert notification.';
    notifyListeners();
  }

  void _updatePersistentLiveSummary() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (!_notificationService.keepAliveEnabled) return;

    final activeCount = _dispatchRows.length;
    final alertCount = _dispatchAlerts.length;
    final uncheckedCallbacks =
        _fslRepository.clearedCalls.where((c) => !c.calledBack).length;
    final clockLabel = FslTimeUtils.formatAccountClock();

    final metaParts = <String>['$activeCount Active'];
    if (_notificationService.showCallbacksInSummary) {
      metaParts.add('$uncheckedCallbacks Callbacks');
    }
    if (_notificationService.showCameraAgeInSummary) {
      metaParts.add('Cam: $cameraLastUpdateAgeText');
    }
    final metaSummary = metaParts.join(' • ');
    final syncFooter = _lastFslUpdatedLabel != null
        ? 'Synced $_lastFslUpdatedLabel'
        : clockLabel;

    if (alertCount > 0) {
      final title =
          '⚠ $alertCount Alert${alertCount == 1 ? "" : "s"} • $metaSummary';

      // Collapsed view shows the active alerts right on the first line so the user
      // never has to expand the notification just to see what the alert is.
      final collapsedAlerts = _dispatchAlerts
          .map((a) {
            final cleanDriver = a.driverName.split('*').first.trim();
            return '[${a.type.code}] $cleanDriver (${a.callId})';
          })
          .join(' • ');

      final expandedLines = <String>[];
      for (final a in _dispatchAlerts.take(6)) {
        final cleanDriver = a.driverName.split('*').first.trim();
        expandedLines.add(
          '• [${a.type.code}] $cleanDriver (Call ${a.callId}): ${a.detail}',
        );
      }
      if (alertCount > 6) {
        expandedLines.add('• +${alertCount - 6} more active alert(s)');
      }
      expandedLines.add('$metaSummary • $syncFooter');

      unawaited(
        _notificationService.updatePersistentSummary(
          title: title,
          collapsedBody: collapsedAlerts,
          body: expandedLines.join('\n'),
          subText: syncFooter,
        ),
      );
    } else {
      final title = 'AAA Tracker • $metaSummary';
      final statusLine = 'No active alerts • $syncFooter';
      unawaited(
        _notificationService.updatePersistentSummary(
          title: title,
          collapsedBody: statusLine,
          body: statusLine,
          subText: clockLabel,
        ),
      );
    }
  }

  Future<void> initialize() async {
    await _authService.loadSavedSessions();
    await _fslRepository.loadDiskCache();
    await _loadCameraAutoRefreshSettings();
    await _notificationService.initialize();
    _startClockTickTimer();
    // Attempt to sync from open desktop browser (if running on Desktop), or refresh via saved credentials
    if (!kIsWeb &&
        defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      final synced = await _authService.syncFromOpenBrowserCdp();
      if (synced.fslSynced || synced.motiveAccountsSynced > 0) {
        _statusBannerText = synced.message;
      } else if (!_authService.hasFslSession &&
          _authService.hasSavedFslCredentials) {
        await _authService.refreshFslSessionAutomatically();
      }
    } else if (!_authService.hasFslSession &&
        _authService.hasSavedFslCredentials) {
      await _authService.refreshFslSessionAutomatically();
    }
    notifyListeners();

    if (_authService.hasFslSession) {
      unawaited(pollFslNow(fullShiftReload: true));
      _startFslPolling();
    }
    if (_authService.hasMotiveSession) {
      unawaited(syncMotiveFleet());
      _startMotivePolling();
      _restartCameraAutoRefreshTimer();
    }
  }

  Future<void> _loadCameraAutoRefreshSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt(_prefAutoRefreshCamMin) ?? 0;
      _cameraAutoRefreshMinutes =
          const {0, 5, 10, 15, 30}.contains(saved) ? saved : 0;
    } catch (_) {}
  }

  void _startClockTickTimer() {
    _clockTickTimer?.cancel();
    _clockTickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      clockTickNotifier.value++;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (_cameraAutoRefreshMinutes > 0 &&
          _nextAutoRefreshEpochMs != null &&
          nowMs >= _nextAutoRefreshEpochMs!) {
        final intervalMs = _cameraAutoRefreshMinutes * 60 * 1000;
        _nextAutoRefreshEpochMs = nowMs + intervalMs;
        unawaited(_triggerScheduledCameraAutoRefresh());
      }
      // Keep persistent notification relative timestamps (e.g. "Cam: 3m ago") updated every 30s
      if (clockTickNotifier.value % 30 == 0 &&
          _notificationService.keepAliveEnabled) {
        _updatePersistentLiveSummary();
      }
    });
  }

  /// Sets the automatic camera refresh interval in minutes (`0` = Off) and restarts
  /// the periodic timer.
  Future<void> setCameraAutoRefreshMinutes(int minutes) async {
    final clamped = minutes < 0 ? 0 : minutes;
    _cameraAutoRefreshMinutes = clamped;
    _restartCameraAutoRefreshTimer();
    _statusBannerText = clamped == 0
        ? 'Camera auto-refresh turned off.'
        : 'Camera auto-refresh set to every $clamped min.';
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefAutoRefreshCamMin, clamped);
    } catch (_) {}
  }

  /// Updates the list of filtered vehicles visible in the Safety Console tab so
  /// periodic auto-refresh refreshes the user's active filter view.
  void updateAutoRefreshTargets(
    List<MotiveVehicle> targets, {
    int? filteredCount,
  }) {
    _autoRefreshTargetVehicles = targets;
    final nextCount = filteredCount ?? targets.length;
    if (filteredCameraCountNotifier.value != nextCount) {
      Future.microtask(() {
        if (!_isDisposed && filteredCameraCountNotifier.value != nextCount) {
          filteredCameraCountNotifier.value = nextCount;
        }
      });
    }
  }

  void _restartCameraAutoRefreshTimer() {
    _cameraAutoRefreshTimer?.cancel();
    _cameraAutoRefreshTimer = null;
    if (_cameraAutoRefreshMinutes <= 0) {
      _nextAutoRefreshEpochMs = null;
      return;
    }

    final intervalMs = _cameraAutoRefreshMinutes * 60 * 1000;
    _nextAutoRefreshEpochMs =
        DateTime.now().millisecondsSinceEpoch + intervalMs;
  }

  Future<void> _triggerScheduledCameraAutoRefresh() async {
    if (!_authService.hasMotiveSession || _isBatchRefreshingCameras) {
      notifyListeners();
      return;
    }

    // Ensure fleet motion statuses are fresh before selecting auto-refresh targets
    if (!_isMotiveLoading) {
      try {
        _motiveVehicles = await _motiveRepository.syncAllVehicles();
        _relinkDriversAndTrucks();
      } catch (_) {}
    }

    final byId = <String, MotiveVehicle>{
      for (final v in _motiveVehicles) v.id: v,
    };

    List<MotiveVehicle> candidates = const [];
    final explicitTargets = _autoRefreshTargetVehicles;
    if (explicitTargets != null && explicitTargets.isNotEmpty) {
      candidates = explicitTargets
          .map((t) => byId[t.id] ?? t)
          .where((v) => v.hasCamera && !v.isPoweredOff)
          .toList(growable: false);
    }

    // Fallback when Safety Console tab hasn't been opened yet or explicit list was empty
    if (candidates.isEmpty && _motiveVehicles.isNotEmpty) {
      candidates = _motiveVehicles
          .where(
            (v) =>
                v.hasCamera &&
                !v.isPoweredOff &&
                (v.motionCategory == VehicleMotionCategory.transit ||
                    v.motionCategory == VehicleMotionCategory.idle),
          )
          .toList(growable: false);
      if (candidates.isEmpty) {
        candidates = _motiveVehicles
            .where((v) => v.hasCamera && !v.isPoweredOff)
            .toList(growable: false);
      }
    }

    if (candidates.isNotEmpty) {
      await refreshBatchCameras(
        targets: candidates,
        includePoweredOff: false,
      );
    } else {
      notifyListeners();
    }
  }

  /// Syncs active Salesforce FSL and Motive sessions from an open Chrome browser
  /// on port 9222 and triggers immediate data synchronization.
  Future<String> syncSessionsFromBrowser() async {
    _statusBannerText = 'Scanning open browser for FSL & Motive sessions...';
    notifyListeners();
    final res = await _authService.syncFromOpenBrowserCdp();
    _statusBannerText = res.message;
    notifyListeners();

    if (_authService.hasFslSession) {
      _startFslPolling();
      unawaited(pollFslNow(fullShiftReload: true));
    }
    if (_authService.hasMotiveSession) {
      _startMotivePolling();
      _restartCameraAutoRefreshTimer();
      unawaited(syncMotiveFleet());
    }
    return res.message;
  }

  void selectTab(int index, {String? focusVehicleId}) {
    _selectedTabIndex = index;
    _focusedMotiveVehicleId = focusVehicleId;
    notifyListeners();
  }

  void clearFocusedVehicle() {
    if (_focusedMotiveVehicleId != null) {
      _focusedMotiveVehicleId = null;
      notifyListeners();
    }
  }

  MotiveVehicle? findVehicleById(String vehicleId) {
    for (final v in _motiveVehicles) {
      if (v.id == vehicleId) return v;
    }
    return null;
  }

  void _startFslPolling() {
    _fslPollTimer?.cancel();
    _fslPollTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => pollFslNow(fullShiftReload: false),
    );
  }

  void _startMotivePolling() {
    _motivePollTimer?.cancel();
    _motivePollTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => syncMotiveFleet(),
    );
  }

  Future<void> pollFslNow({bool fullShiftReload = false}) async {
    if ((!_authService.hasFslSession && !_authService.hasSavedFslCredentials) ||
        _isFslLoading) {
      return;
    }
    _startFslPolling();
    _isFslLoading = true;
    _lastFslError = null;
    notifyListeners();

    try {
      if (!_authService.hasFslSession && _authService.hasSavedFslCredentials) {
        await _authService.refreshFslSessionAutomatically();
      }
      var res = await _fslRepository
          .pollDelta(fullShiftReload: fullShiftReload)
          .catchError((Object firstErr) async {
            // If session cookie expired, automatically refresh via saved credentials
            // first (100% standalone on Android/Desktop), then fallback to browser CDP.
            final refreshed =
                await _authService.refreshFslSessionAutomatically();
            if (refreshed.refreshed) {
              return await _fslRepository.pollDelta(fullShiftReload: true);
            }
            throw firstErr;
          });
      _dispatchRows = res.rows;
      _dispatchAlerts = res.alerts;
      _lastFslUpdatedLabel = FslTimeUtils.formatCentralTime(
        DateTime.now().millisecondsSinceEpoch,
      );
      _relinkDriversAndTrucks();
      unawaited(_notificationService.processAlerts(_dispatchAlerts));
      _updatePersistentLiveSummary();
      _statusBannerText =
          'FSL live: ${_dispatchRows.length} active drivers, ${_dispatchAlerts.length} alerts.';
      unawaited(_pumpBacklogEnrichment());
    } catch (e) {
      _lastFslError = e.toString();
      _statusBannerText = 'FSL sync error: $e';
    } finally {
      _isFslLoading = false;
      notifyListeners();
    }
  }

  Future<void> _pumpBacklogEnrichment() async {
    if (_isEnrichingBacklog) return;
    _isEnrichingBacklog = true;
    try {
      while (_authService.hasFslSession) {
        final didEnrich = await _fslRepository.enrichNextBacklogBatch(
          maxParallelRequests: 16,
        );
        if (!didEnrich) break;
        // Only rebuild UI while pumping backlog if the user is currently viewing the Callbacks tab
        if (_selectedTabIndex == 1) {
          notifyListeners();
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      _updatePersistentLiveSummary();
      notifyListeners();
    } catch (_) {
    } finally {
      _isEnrichingBacklog = false;
    }
  }

  Future<void> syncMotiveFleet() async {
    if (!_authService.hasMotiveSession || _isMotiveLoading) return;
    _startMotivePolling();
    if (_cameraAutoRefreshMinutes > 0 && _nextAutoRefreshEpochMs == null) {
      _restartCameraAutoRefreshTimer();
    }
    _isMotiveLoading = true;
    notifyListeners();

    try {
      _motiveVehicles = await _motiveRepository.syncAllVehicles();
      _syncLastCameraRefreshTimestamp();
      _relinkDriversAndTrucks();
      _updatePersistentLiveSummary();
      _statusBannerText =
          'Motive fleet synced: ${_motiveVehicles.length} vehicles.';
    } catch (e) {
      _statusBannerText = 'Motive sync error: $e';
    } finally {
      _isMotiveLoading = false;
      notifyListeners();
    }
  }

  void _syncLastCameraRefreshTimestamp() {
    int? maxTs = _lastCameraRefreshEpochMs;
    for (final v in _motiveVehicles) {
      final ts = v.lastRefreshedEpochMs;
      if (ts != null && (maxTs == null || ts > maxTs)) {
        maxTs = ts;
      }
    }
    _lastCameraRefreshEpochMs = maxTs;
  }

  Future<MotiveVehicle?> refreshSingleCamera(String vehicleId) async {
    _statusBannerText = 'Refreshing camera for vehicle $vehicleId...';
    notifyListeners();
    try {
      final updated = await _motiveRepository.refreshSingleVehicleCamera(
        vehicleId,
      );
      if (updated != null) {
        _motiveVehicles = _motiveRepository.vehicles;
        if (updated.lastRefreshedEpochMs != null) {
          _lastCameraRefreshEpochMs = updated.lastRefreshedEpochMs;
        }
        _relinkDriversAndTrucks();
        _updatePersistentLiveSummary();
        _statusBannerText =
            'Updated camera for ${updated.name} (${updated.cameraStatusText}).';
        notifyListeners();
        return findVehicleById(vehicleId) ?? updated;
      }
    } catch (e) {
      _statusBannerText = 'Camera refresh error ($vehicleId): $e';
      notifyListeners();
    }
    return null;
  }

  Future<void> refreshBatchCameras({
    required List<MotiveVehicle> targets,
    bool includePoweredOff = false,
  }) async {
    if (_isBatchRefreshingCameras) return;
    _isBatchRefreshingCameras = true;
    _statusBannerText =
        'Refreshing ${targets.length} target cameras...';
    notifyListeners();

    try {
      await _motiveRepository.refreshBatchVehicles(
        targetVehicles: targets,
        includePoweredOff: includePoweredOff,
        onVehicleUpdated: (updated, completed, total) {
          _motiveVehicles = _motiveRepository.vehicles;
          if (updated.lastRefreshedEpochMs != null) {
            _lastCameraRefreshEpochMs = updated.lastRefreshedEpochMs;
          }
          _relinkDriversAndTrucks();
          _statusBannerText =
              'Refreshed $completed / $total cameras (${updated.name}: ${updated.cameraStatusText})';
          notifyListeners();
        },
      );
      _syncLastCameraRefreshTimestamp();
      _updatePersistentLiveSummary();
      _statusBannerText = 'Batch camera refresh complete.';
    } finally {
      _isBatchRefreshingCameras = false;
      notifyListeners();
    }
  }

  void stopBatchCameraRefresh() {
    _motiveRepository.cancelBatchRefresh();
    _statusBannerText = 'Stopping batch camera refresh...';
    notifyListeners();
  }

  void toggleClearedCallCalledBack(String callId) {
    _fslRepository.toggleCalledBack(callId);
    _updatePersistentLiveSummary();
    notifyListeners();
  }

  void _relinkDriversAndTrucks() {
    if (_dispatchRows.isEmpty && _motiveVehicles.isEmpty) return;
    final linked = DriverTruckLinker.linkAll(
      rows: _dispatchRows,
      vehicles: _motiveVehicles,
    );
    _dispatchRows = linked.rows;
    _motiveVehicles = linked.vehicles;
    _triggerAlertCameraAutoRefreshes();
  }

  /// Automatically refreshes the camera for any driver with an active alert
  /// and a linked Motive truck (with a 10-minute per-alert cooldown),
  /// serialized so multiple simultaneous alerts don't stampede the network/UI.
  void _triggerAlertCameraAutoRefreshes() {
    if (!_authService.hasMotiveSession) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // Prune expired alert keys older than 15 minutes
    _autoRefreshedAlertKeys.removeWhere((_, ts) => (nowMs - ts) > 15 * 60000);

    for (final row in _dispatchRows) {
      final link = row.linkedTruck;
      if (row.alerts.isEmpty || link == null) continue;
      final vehicleId = link.motiveVehicleId;
      if (_inFlightAlertCameraVehicleIds.contains(vehicleId)) continue;

      var shouldRefresh = false;
      for (final alert in row.alerts) {
        final key =
            '${alert.type.name}:${row.serviceAppointmentId}:${row.resourceId}';
        final lastRefreshed = _autoRefreshedAlertKeys[key];
        if (lastRefreshed == null || (nowMs - lastRefreshed) >= 10 * 60000) {
          _autoRefreshedAlertKeys[key] = nowMs;
          shouldRefresh = true;
        }
      }

      if (shouldRefresh) {
        _inFlightAlertCameraVehicleIds.add(vehicleId);
      }
    }

    if (_inFlightAlertCameraVehicleIds.isNotEmpty && !_isPumpingAlertCameras) {
      unawaited(_pumpAlertCameraQueue());
    }
  }

  Future<void> _pumpAlertCameraQueue() async {
    if (_isPumpingAlertCameras) return;
    _isPumpingAlertCameras = true;
    try {
      while (_inFlightAlertCameraVehicleIds.isNotEmpty) {
        final vehicleId = _inFlightAlertCameraVehicleIds.first;
        try {
          await refreshSingleCamera(vehicleId);
        } finally {
          _inFlightAlertCameraVehicleIds.remove(vehicleId);
        }
      }
    } finally {
      _isPumpingAlertCameras = false;
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _fslPollTimer?.cancel();
    _motivePollTimer?.cancel();
    _cameraAutoRefreshTimer?.cancel();
    _clockTickTimer?.cancel();
    clockTickNotifier.dispose();
    filteredCameraCountNotifier.dispose();
    super.dispose();
  }
}
