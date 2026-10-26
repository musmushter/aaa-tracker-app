import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../data/repositories/fsl_repository.dart';
import '../../../../data/repositories/motive_repository.dart';
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
  });

  static const String _prefAutoRefreshCamMin = 'safety_auto_refresh_minutes_v1';

  final AuthSessionService _authService;
  final FslRepository _fslRepository;
  final MotiveRepository _motiveRepository;

  AuthSessionService get authService => _authService;

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
  bool _isEnrichingBacklog = false;

  /// Current filtered vehicles from the Safety Console tab used as targets for auto-refresh.
  List<MotiveVehicle>? _autoRefreshTargetVehicles;

  /// Tracks alert keys (`type:saId:resourceId` -> epochMs) that have already triggered
  /// an automatic camera refresh so we refresh immediately on new alerts without spamming.
  final Map<String, int> _autoRefreshedAlertKeys = {};
  final Set<String> _inFlightAlertCameraVehicleIds = {};

  Future<void> initialize() async {
    await _authService.loadSavedSessions();
    await _fslRepository.loadDiskCache();
    await _loadCameraAutoRefreshSettings();
    // Attempt to sync from open desktop browser (if running), or refresh via saved credentials
    final synced = await _authService.syncFromOpenBrowserCdp();
    if (synced.fslSynced || synced.motiveAccountsSynced > 0) {
      _statusBannerText = synced.message;
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
      _cameraAutoRefreshMinutes = prefs.getInt(_prefAutoRefreshCamMin) ?? 0;
    } catch (_) {}
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
  void updateAutoRefreshTargets(List<MotiveVehicle> targets) {
    _autoRefreshTargetVehicles = targets;
  }

  void _restartCameraAutoRefreshTimer() {
    _cameraAutoRefreshTimer?.cancel();
    _cameraAutoRefreshTimer = null;
    if (_cameraAutoRefreshMinutes <= 0) return;

    _cameraAutoRefreshTimer = Timer.periodic(
      Duration(minutes: _cameraAutoRefreshMinutes),
      (_) {
        if (!_authService.hasMotiveSession || _isBatchRefreshingCameras) {
          return;
        }
        final candidates = _autoRefreshTargetVehicles ?? _motiveVehicles;
        final activeTargets = candidates
            .where((v) => !v.isPoweredOff)
            .toList(growable: false);
        if (activeTargets.isNotEmpty) {
          unawaited(
            refreshBatchCameras(
              targets: activeTargets,
              includePoweredOff: false,
            ),
          );
        }
      },
    );
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
        notifyListeners();
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    } catch (_) {
    } finally {
      _isEnrichingBacklog = false;
    }
  }

  Future<void> syncMotiveFleet() async {
    if (!_authService.hasMotiveSession || _isMotiveLoading) return;
    _startMotivePolling();
    _isMotiveLoading = true;
    notifyListeners();

    try {
      _motiveVehicles = await _motiveRepository.syncAllVehicles();
      _relinkDriversAndTrucks();
      _statusBannerText =
          'Motive fleet synced: ${_motiveVehicles.length} vehicles.';
    } catch (e) {
      _statusBannerText = 'Motive sync error: $e';
    } finally {
      _isMotiveLoading = false;
      notifyListeners();
    }
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
        _relinkDriversAndTrucks();
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
          _relinkDriversAndTrucks();
          _statusBannerText =
              'Refreshed $completed / $total cameras (${updated.name}: ${updated.cameraStatusText})';
          notifyListeners();
        },
      );
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
  /// and a linked Motive truck (with a 10-minute per-alert cooldown).
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
        unawaited(() async {
          try {
            await refreshSingleCamera(vehicleId);
          } finally {
            _inFlightAlertCameraVehicleIds.remove(vehicleId);
          }
        }());
      }
    }
  }

  @override
  void dispose() {
    _fslPollTimer?.cancel();
    _motivePollTimer?.cancel();
    _cameraAutoRefreshTimer?.cancel();
    super.dispose();
  }
}
