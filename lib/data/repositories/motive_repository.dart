import '../../domain/models/motive_vehicle.dart';
import '../models/motive_api_models.dart';
import '../services/auth_session_service.dart';
import '../services/motive_api_client.dart';
import '../services/snapshot_storage_service.dart';

/// Single source of truth for Motive fleet vehicles and dashcam refresh operations.
///
/// No hardcoded user IDs, company IDs, or group maps, and no `< 3` associations
/// filter override bugs.
class MotiveRepository {
  MotiveRepository({
    required this._apiClient,
    required this._authService,
    required this._snapshotStorage,
  });

  final MotiveApiClient _apiClient;
  final AuthSessionService _authService;
  final SnapshotStorageService _snapshotStorage;

  final Map<String, MotiveVehicle> _vehiclesById = {};
  bool _cancelBatchRequested = false;

  List<MotiveVehicle> get vehicles => _vehiclesById.values.toList();

  /// Syncs vehicles across all configured [MotiveAccountSession]s in parallel.
  Future<List<MotiveVehicle>> syncAllVehicles() async {
    await _snapshotStorage.pruneExpiredSnapshots();

    final accounts = _authService.motiveAccounts;
    if (accounts.isEmpty) return _vehiclesById.values.toList();

    final futures = accounts.map((account) async {
      try {
        return await _apiClient.fetchVehiclesForAccount(account);
      } catch (_) {
        return const <MotiveVehicle>[];
      }
    });

    final accountLists = await Future.wait(futures);
    for (final list in accountLists) {
      for (final fetched in list) {
        final existing = _vehiclesById[fetched.id];
        if (existing != null) {
          // Preserve captured camera state & 3-strike timeout counter across fleet syncs,
          // but automatically clear a prior timeout-based powered-off lock if Motive
          // reports the truck is now actively In Transit or Idling.
          final mergedMap = <String, String>{
            ...fetched.cameraPathsByAngle,
            ...existing.cameraPathsByAngle,
          };
          final wokeUp =
              !fetched.isPoweredOff &&
              fetched.motionCategory != VehicleMotionCategory.stationary;
          final effectivePoweredOff = wokeUp
              ? false
              : (fetched.isPoweredOff || existing.isPoweredOff);
          final effectiveTimeouts = wokeUp ? 0 : existing.consecutiveTimeouts;
          final existingTs = existing.lastRefreshedEpochMs;
          final fetchedTs = fetched.lastRefreshedEpochMs;
          final bestTs = (existingTs != null && fetchedTs != null)
              ? (existingTs > fetchedTs ? existingTs : fetchedTs)
              : (existingTs ?? fetchedTs);

          _vehiclesById[fetched.id] = fetched.copyWith(
            eldIdentifier: fetched.eldIdentifier ?? existing.eldIdentifier,
            driverCameraPath:
                existing.driverCameraPath ?? fetched.driverCameraPath,
            roadCameraPath: existing.roadCameraPath ?? fetched.roadCameraPath,
            cameraPathsByAngle: mergedMap,
            cameraStatusText: existingTs != null
                ? existing.cameraStatusText
                : fetched.cameraStatusText,
            lastRefreshedEpochMs: bestTs,
            consecutiveTimeouts: effectiveTimeouts,
            isPoweredOff: effectivePoweredOff,
            offlineReason: effectivePoweredOff
                ? (fetched.offlineReason ?? existing.offlineReason)
                : '',
            linkedFslDriver: existing.linkedFslDriver,
          );
        } else {
          _vehiclesById[fetched.id] = fetched;
        }
      }
    }

    return _vehiclesById.values.toList();
  }

  /// Refreshes the dashcam snapshots for a single [vehicleId].
  Future<MotiveVehicle?> refreshSingleVehicleCamera(String vehicleId) async {
    final vehicle = _vehiclesById[vehicleId];
    if (vehicle == null) return null;

    final account = _authService.motiveAccounts.firstWhere(
      (a) => a.organizationId == vehicle.organizationId,
      orElse: () => _authService.motiveAccounts.first,
    );

    final updated = await _apiClient.refreshVehicleCamera(
      vehicle: vehicle,
      account: account,
    );
    _vehiclesById[vehicleId] = updated;
    return updated;
  }

  /// Batch-refreshes a target list of vehicles with bounded concurrency (default 4),
  /// invoking [onVehicleUpdated] after each truck finishes so the UI updates live.
  Future<void> refreshBatchVehicles({
    required List<MotiveVehicle> targetVehicles,
    required void Function(MotiveVehicle updated, int completed, int total)
    onVehicleUpdated,
    bool includePoweredOff = false,
    int concurrency = 4,
  }) async {
    _cancelBatchRequested = false;
    final seenIds = <String>{};
    final queue = targetVehicles
        .where(
          (v) =>
              v.hasCamera &&
              (includePoweredOff || !v.isPoweredOff) &&
              seenIds.add(v.id),
        )
        .toList();
    if (queue.isEmpty) return;

    int nextIndex = 0;
    int completedCount = 0;
    final total = queue.length;

    Future<void> worker() async {
      while (!_cancelBatchRequested) {
        if (nextIndex >= queue.length) break;
        final item = queue[nextIndex++];
        MotiveVehicle? updated;
        try {
          updated = await refreshSingleVehicleCamera(item.id);
        } catch (_) {
          updated = _vehiclesById[item.id] ?? item;
        }
        completedCount++;
        onVehicleUpdated(
          updated ?? _vehiclesById[item.id] ?? item,
          completedCount,
          total,
        );
      }
    }

    final workerCount = concurrency.clamp(1, queue.length);
    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  void cancelBatchRefresh() {
    _cancelBatchRequested = true;
  }
}
