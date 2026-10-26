import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Manages dashcam snapshot files on disk with a strict bounded storage policy.
///
/// Fixes the old `snapshots/` bloat issue by:
/// 1. Using deterministic per-vehicle filenames (`{vehicleId}_driver.jpg` and
///    `{vehicleId}_road.jpg`) so new refreshes overwrite old frames instead of
///    accumulating thousands of timestamped files.
/// 2. Pruning any orphaned snapshot files older than [maxAge].
class SnapshotStorageService {
  SnapshotStorageService({this.maxAge = const Duration(hours: 24)});

  final Duration maxAge;
  Directory? _snapshotsDir;

  Future<Directory> getSnapshotsDirectory() async {
    if (_snapshotsDir != null) return _snapshotsDir!;
    final baseDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(baseDir.path, 'snapshots'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _snapshotsDir = dir;
    return dir;
  }

  static const List<String> supportedAngles = [
    'driver',
    'road',
    'front_narrow',
    'rear',
    'side_left',
    'side_right',
  ];

  /// Writes a camera snapshot for [vehicleId] and [cameraAngle] (`'driver'`,
  /// `'road'`, `'front_narrow'`, `'rear'`, `'side_left'`, `'side_right'`),
  /// overwriting the previous snapshot for that vehicle and angle.
  Future<String> saveSnapshot({
    required String vehicleId,
    required String cameraAngle,
    required Uint8List bytes,
  }) async {
    final dir = await getSnapshotsDirectory();
    final safeId = vehicleId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final safeAngle = supportedAngles.contains(cameraAngle)
        ? cameraAngle
        : cameraAngle.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final filePath = p.join(dir.path, '${safeId}_$safeAngle.jpg');
    final file = File(filePath);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// Writes the stitched collage PNG for [vehicleId] to disk so it can be
  /// shared or copied to the system clipboard.
  Future<String> saveStitchedReportImage({
    required String vehicleId,
    required Uint8List pngBytes,
  }) async {
    final dir = await getSnapshotsDirectory();
    final safeId = vehicleId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final filePath = p.join(dir.path, '${safeId}_stitched.png');
    final file = File(filePath);
    await file.writeAsBytes(pngBytes, flush: true);
    return file.path;
  }

  /// Returns existing cached snapshot paths for [vehicleId] across all angles,
  /// plus the latest file modification timestamp if any exists.
  Future<
    ({
      String? driverPath,
      String? roadPath,
      Map<String, String> byAngle,
      int? lastModifiedEpochMs,
    })
  >
  getExistingSnapshots(String vehicleId) async {
    final dir = await getSnapshotsDirectory();
    final safeId = vehicleId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final byAngle = <String, String>{};
    int? latestModifiedMs;

    for (final angle in supportedAngles) {
      final file = File(p.join(dir.path, '${safeId}_$angle.jpg'));
      if (await file.exists()) {
        byAngle[angle] = file.path;
        try {
          final stat = await file.stat();
          final ms = stat.modified.millisecondsSinceEpoch;
          if (latestModifiedMs == null || ms > latestModifiedMs) {
            latestModifiedMs = ms;
          }
        } catch (_) {}
      }
    }

    return (
      driverPath: byAngle['driver'],
      roadPath: byAngle['road'],
      byAngle: byAngle,
      lastModifiedEpochMs: latestModifiedMs,
    );
  }

  /// Removes any snapshot or stitched files older than [maxAge] to keep disk usage minimal.
  Future<int> pruneExpiredSnapshots() async {
    final dir = await getSnapshotsDirectory();
    if (!await dir.exists()) return 0;

    final cutoff = DateTime.now().subtract(maxAge);
    int deletedCount = 0;

    await for (final entity in dir.list(followLinks: false)) {
      final ext = p.extension(entity.path).toLowerCase();
      if (entity is File && (ext == '.jpg' || ext == '.png')) {
        try {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entity.delete();
            deletedCount++;
          }
        } catch (_) {
          // Ignore individual file errors during cleanup
        }
      }
    }
    return deletedCount;
  }
}
