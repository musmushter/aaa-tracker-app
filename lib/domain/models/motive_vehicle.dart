import '../use_cases/fsl_time_utils.dart';
import 'driver_truck_link.dart';

enum VehicleMotionCategory {
  transit('transit', 'In Transit'),
  idle('idle', 'Idling'),
  stationary('stationary', 'Stationary');

  const VehicleMotionCategory(this.key, this.label);
  final String key;
  final String label;
}

/// Clean domain model for a Motive fleet vehicle and its dashcam state.
///
/// No hardcoded org IDs, user IDs, or group maps: organization and group names
/// are populated dynamically from the Motive API response.
class MotiveVehicle {
  MotiveVehicle({
    required this.id,
    required this.name,
    required this.organizationId,
    required this.organizationName,
    required this.associationGroup,
    required this.assignedDriverName,
    required this.makeModelYear,
    required this.statusText,
    required this.motionCategory,
    required this.speedMph,
    required this.hasCamera,
    required this.isPoweredOff,
    this.offlineReason,
    this.eldDeviceId,
    this.eldIdentifier,
    this.latitude,
    this.longitude,
    this.locatedAtIso,
    this.driverCameraPath,
    this.roadCameraPath,
    Map<String, String>? cameraPathsByAngle,
    this.cameraStatusText = 'Ready to refresh',
    this.lastRefreshedEpochMs,
    this.consecutiveTimeouts = 0,
    this.linkedFslDriver,
  }) : cameraPathsByAngle = _normalizeCameraMap(
         cameraPathsByAngle: cameraPathsByAngle,
         driverCameraPath: driverCameraPath,
         roadCameraPath: roadCameraPath,
       );

  static const List<({String key, String label})> orderedCameraAngles = [
    (key: 'driver', label: 'Driver Cam'),
    (key: 'road', label: 'Road Cam'),
    (key: 'front_narrow', label: 'Narrow Road'),
    (key: 'rear', label: 'Rear Cam'),
    (key: 'side_left', label: 'Left Side'),
    (key: 'side_right', label: 'Right Side'),
  ];

  static Map<String, String> _normalizeCameraMap({
    Map<String, String>? cameraPathsByAngle,
    String? driverCameraPath,
    String? roadCameraPath,
  }) {
    final map = <String, String>{};
    if (cameraPathsByAngle != null) {
      for (final entry in cameraPathsByAngle.entries) {
        if (entry.value.isNotEmpty) {
          map[entry.key] = entry.value;
        }
      }
    }
    if (driverCameraPath != null && driverCameraPath.isNotEmpty) {
      map['driver'] = driverCameraPath;
    }
    if (roadCameraPath != null && roadCameraPath.isNotEmpty) {
      map['road'] = roadCameraPath;
    }
    return Map.unmodifiable(map);
  }

  static String labelForAngle(String angleKey) {
    for (final item in orderedCameraAngles) {
      if (item.key == angleKey) return item.label;
    }
    return angleKey;
  }

  final String id;
  final String name;
  final String organizationId;
  final String organizationName;
  final String associationGroup;
  final String assignedDriverName;
  final String makeModelYear;
  final String statusText;
  final VehicleMotionCategory motionCategory;
  final double speedMph;
  final bool hasCamera;
  final bool isPoweredOff;
  final String? offlineReason;
  final int? eldDeviceId;
  final String? eldIdentifier;
  final double? latitude;
  final double? longitude;
  final String? locatedAtIso;

  /// Local file paths to the latest bounded snapshots on disk.
  final String? driverCameraPath;
  final String? roadCameraPath;

  /// All available camera angle file paths keyed by angle (`driver`, `road`,
  /// `front_narrow`, `rear`, `side_left`, `side_right`).
  final Map<String, String> cameraPathsByAngle;

  final String cameraStatusText;
  final int? lastRefreshedEpochMs;
  final int consecutiveTimeouts;

  /// Automatic multi-signal link back to an active FSL driver, if matched.
  final DriverTruckLink? linkedFslDriver;

  bool get hasImages => cameraPathsByAngle.isNotEmpty;

  /// Ordered list of available camera entries, with `driver` always first if present.
  List<({String key, String label, String path})> get availableCameraEntries {
    final entries = <({String key, String label, String path})>[];
    for (final angle in orderedCameraAngles) {
      final path = cameraPathsByAngle[angle.key];
      if (path != null && path.isNotEmpty) {
        entries.add((key: angle.key, label: angle.label, path: path));
      }
    }
    for (final entry in cameraPathsByAngle.entries) {
      if (!orderedCameraAngles.any((a) => a.key == entry.key) &&
          entry.value.isNotEmpty) {
        entries.add((
          key: entry.key,
          label: labelForAngle(entry.key),
          path: entry.value,
        ));
      }
    }
    return entries;
  }

  /// Main camera entry for the card & stitched report (Driver Cam if available,
  /// otherwise the first available camera view).
  ({String key, String label, String path})? get mainCameraEntry {
    final entries = availableCameraEntries;
    if (entries.isEmpty) return null;
    for (final entry in entries) {
      if (entry.key == 'driver') return entry;
    }
    return entries.first;
  }

  /// All other available camera views beyond [mainCameraEntry], rendered as
  /// small thumbnails above the main view.
  List<({String key, String label, String path})> get thumbnailCameraEntries {
    final main = mainCameraEntry;
    if (main == null) return const [];
    return availableCameraEntries
        .where((e) => e.key != main.key)
        .toList(growable: false);
  }

  /// Short corner age badge for when the camera snapshot was last updated:
  /// `'Now'`, `'2m'`, `'5m'`, `'1h'`, etc.
  String shortAgeLabel({int? nowEpochMs}) {
    final ts = lastRefreshedEpochMs;
    if (ts == null || ts <= 0) return '';
    final now = nowEpochMs ?? DateTime.now().millisecondsSinceEpoch;
    final diffSec = ((now - ts) / 1000).round();
    if (diffSec < 90) return 'Now';
    if (diffSec < 3600) {
      final mins = (diffSec / 60).round().clamp(1, 59);
      return '${mins}m';
    }
    if (diffSec < 86400) {
      final hours = (diffSec / 3600).floor().clamp(1, 23);
      return '${hours}h';
    }
    final days = (diffSec / 86400).floor();
    return '${days}d';
  }

  /// Returns the associated driver's clean name if one exists (from Motive
  /// assignment, linked FSL driver, or embedded in the vehicle label), or `null`
  /// if no driver is associated.
  String? get effectiveDriverName {
    final assigned = assignedDriverName.trim();
    if (assigned.isNotEmpty && assigned.toLowerCase() != 'unassigned') {
      final cleanedAssigned = FslTimeUtils.tryExtractCleanDriverName(assigned);
      if (cleanedAssigned != null && cleanedAssigned.isNotEmpty) {
        return cleanedAssigned;
      }
    }
    final linked = linkedFslDriver?.fslDriverName.trim();
    if (linked != null && linked.isNotEmpty) {
      final cleanedLinked = FslTimeUtils.tryExtractCleanDriverName(linked);
      if (cleanedLinked != null && cleanedLinked.isNotEmpty) {
        return cleanedLinked;
      }
    }
    return FslTimeUtils.tryExtractCleanDriverName(name);
  }

  String get liveMotiveUrl =>
      'https://app.gomotive.com/en-US/#/fleetview/map/vehicle/$id-null-null/$id/live';

  MotiveVehicle copyWith({
    String? statusText,
    VehicleMotionCategory? motionCategory,
    double? speedMph,
    bool? isPoweredOff,
    String? offlineReason,
    String? eldIdentifier,
    double? latitude,
    double? longitude,
    String? locatedAtIso,
    String? driverCameraPath,
    String? roadCameraPath,
    Map<String, String>? cameraPathsByAngle,
    String? cameraStatusText,
    int? lastRefreshedEpochMs,
    int? consecutiveTimeouts,
    DriverTruckLink? linkedFslDriver,
  }) {
    final nextDriverPath = driverCameraPath ?? this.driverCameraPath;
    final nextRoadPath = roadCameraPath ?? this.roadCameraPath;
    final mergedMap = <String, String>{
      ...this.cameraPathsByAngle,
      ...?cameraPathsByAngle,
      if (nextDriverPath != null && nextDriverPath.isNotEmpty)
        'driver': nextDriverPath,
      if (nextRoadPath != null && nextRoadPath.isNotEmpty) 'road': nextRoadPath,
    };

    return MotiveVehicle(
      id: id,
      name: name,
      organizationId: organizationId,
      organizationName: organizationName,
      associationGroup: associationGroup,
      assignedDriverName: assignedDriverName,
      makeModelYear: makeModelYear,
      statusText: statusText ?? this.statusText,
      motionCategory: motionCategory ?? this.motionCategory,
      speedMph: speedMph ?? this.speedMph,
      hasCamera: hasCamera,
      isPoweredOff: isPoweredOff ?? this.isPoweredOff,
      offlineReason: offlineReason ?? this.offlineReason,
      eldDeviceId: eldDeviceId,
      eldIdentifier: eldIdentifier ?? this.eldIdentifier,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      locatedAtIso: locatedAtIso ?? this.locatedAtIso,
      driverCameraPath: mergedMap['driver'] ?? nextDriverPath,
      roadCameraPath: mergedMap['road'] ?? nextRoadPath,
      cameraPathsByAngle: mergedMap,
      cameraStatusText: cameraStatusText ?? this.cameraStatusText,
      lastRefreshedEpochMs: lastRefreshedEpochMs ?? this.lastRefreshedEpochMs,
      consecutiveTimeouts: consecutiveTimeouts ?? this.consecutiveTimeouts,
      linkedFslDriver: linkedFslDriver ?? this.linkedFslDriver,
    );
  }
}
