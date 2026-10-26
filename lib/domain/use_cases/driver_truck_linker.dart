import '../models/dispatch_row.dart';
import '../models/driver_truck_link.dart';
import '../models/motive_vehicle.dart';
import 'fsl_time_utils.dart';

/// Automatic Multi-Verification Engine linking active FSL drivers to Motive trucks.
///
/// Key rules from live data audit:
/// 1. Ignores unreliable `(xx)` call-sign numbers (which collide or differ across sites).
/// 2. Combines cleaned name tokens (from FSL driver name, Motive vehicle name,
///    and Motive assigned driver) with live GPS proximity (`< 250m` strong match)
///    and active motion state (`In Transit` > `Idling` > `Stationary`).
/// 3. Automatically resolves multi-truck drivers (e.g. Derek Holt's active
///    `-F823` vs parked `-F856`, or Jordan Miles's `-F966` vs `-F730`) and
///    detects truck swaps when a driver's FSL GPS tracks right alongside a
///    differently-named moving Motive truck.
class DriverTruckLinker {
  static const double strongGpsMatchMeters = 250.0;
  static const double moderateGpsMatchMeters = 600.0;

  static final Set<String> _noiseTokens = {
    'ls',
    'fb',
    'wl',
    'truck',
    'shop',
    'temp',
    'bmw',
    'heart',
    'all',
    'american',
    'houston',
    'towing',
    'hd',
    'unassigned',
    'driver',
    'union',
    'alpha',
    'india',
    'tango',
    'sierra',
    'nov',
    'vic',
    'romio',
    'sam',
    'gmc',
    'chevy',
  };

  /// Extracts normalized alphabetic name tokens (ignoring call-sign numbers,
  /// unit suffixes like `-F730` or `W301`, and fleet noise words).
  static List<String> extractNameTokens(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    var s = FslTimeUtils.cleanDriverName(raw);
    // Strip unit numbers like -F730, -P690, -AU1016, -WL282, -PR4356, W301
    s = s.replaceAll(
      RegExp(r'[-/\s]*\b[A-Z]{1,3}\d{2,5}\b', caseSensitive: false),
      ' ',
    );
    // Strip Truck#XX
    s = s.replaceAll(RegExp(r'truck\s*#?\s*\d+', caseSensitive: false), ' ');
    final tokens = s
        .toLowerCase()
        .split(RegExp(r'[^a-z]+'))
        .where((t) => t.length >= 3 && !_noiseTokens.contains(t))
        .toList();
    return tokens;
  }

  /// Computes a name similarity score in `[0.0, 1.0]` between an FSL driver
  /// and a Motive vehicle (checking both `vehicle.name` and `vehicle.assignedDriverName`).
  static double computeNameScore(DispatchRow row, MotiveVehicle vehicle) {
    final fslTokens = extractNameTokens(row.driverCleanName);
    if (fslTokens.isEmpty) return 0.0;

    final vehNameTokens = extractNameTokens(vehicle.name);
    final vehDrvTokens = extractNameTokens(vehicle.assignedDriverName);

    final scoreFromTitle = _tokenOverlapScore(fslTokens, vehNameTokens);
    final scoreFromDrv = _tokenOverlapScore(fslTokens, vehDrvTokens);
    return scoreFromTitle > scoreFromDrv ? scoreFromTitle : scoreFromDrv;
  }

  static double _tokenOverlapScore(List<String> a, List<String> b) {
    if (a.isEmpty || b.isEmpty) return 0.0;
    int matches = 0;
    for (final tA in a) {
      if (b.any((tB) => tB == tA || _isClosePrefixMatch(tA, tB))) {
        matches++;
      }
    }
    if (matches == 0) return 0.0;
    // Full first + last name match
    if (matches >= 2) return 1.0;
    // Single-name match (e.g., "DEREK -F823" or "Tyrell-F757" or "Omar")
    if (a.first == b.first || _isClosePrefixMatch(a.first, b.first)) {
      return 0.75;
    }
    return 0.5;
  }

  static bool _isClosePrefixMatch(String a, String b) {
    if (a.length >= 4 && b.length >= 4) {
      return a.startsWith(b.substring(0, 4)) || b.startsWith(a.substring(0, 4));
    }
    return false;
  }

  /// Links a list of [DispatchRow]s and [MotiveVehicle]s, returning updated
  /// copies of both lists with their [DriverTruckLink] populated.
  static ({List<DispatchRow> rows, List<MotiveVehicle> vehicles}) linkAll({
    required List<DispatchRow> rows,
    required List<MotiveVehicle> vehicles,
  }) {
    final candidateLinks = <DriverTruckLink>[];

    for (final row in rows) {
      for (final vehicle in vehicles) {
        final nameScore = computeNameScore(row, vehicle);
        double? gpsMeters;
        if (row.driverLat != null &&
            row.driverLon != null &&
            vehicle.latitude != null &&
            vehicle.longitude != null) {
          gpsMeters = FslTimeUtils.haversineMeters(
            row.driverLat!,
            row.driverLon!,
            vehicle.latitude!,
            vehicle.longitude!,
          );
        }

        final isMovingOrIdle =
            vehicle.motionCategory == VehicleMotionCategory.transit ||
            vehicle.motionCategory == VehicleMotionCategory.idle;
        final motionBonus =
            vehicle.motionCategory == VehicleMotionCategory.transit
            ? 0.18
            : (vehicle.motionCategory == VehicleMotionCategory.idle
                  ? 0.10
                  : 0.0);

        LinkVerificationSignal? signal;
        double confidence = 0.0;

        if (nameScore >= 0.70 &&
            gpsMeters != null &&
            gpsMeters <= moderateGpsMatchMeters) {
          signal = LinkVerificationSignal.gpsAndName;
          final gpsScore =
              1.0 - (gpsMeters / moderateGpsMatchMeters).clamp(0.0, 0.4);
          confidence = (0.55 * nameScore + 0.35 * gpsScore + motionBonus).clamp(
            0.0,
            1.0,
          );
        } else if (nameScore < 0.50 &&
            gpsMeters != null &&
            gpsMeters <= strongGpsMatchMeters &&
            isMovingOrIdle) {
          // Physical GPS co-location while moving/idling indicates a truck swap
          signal = LinkVerificationSignal.gpsProximitySwap;
          final gpsScore =
              1.0 - (gpsMeters / strongGpsMatchMeters).clamp(0.0, 0.5);
          confidence = (0.70 * gpsScore + motionBonus).clamp(0.0, 0.89);
        } else if (nameScore >= 0.70 && isMovingOrIdle) {
          signal = LinkVerificationSignal.nameAndActiveMotion;
          confidence = (0.65 * nameScore + motionBonus).clamp(0.0, 0.90);
        } else if (nameScore >= 0.75) {
          signal = LinkVerificationSignal.nameOnly;
          confidence = (0.55 * nameScore).clamp(0.0, 0.70);
        }

        if (signal != null && confidence >= 0.40) {
          candidateLinks.add(
            DriverTruckLink(
              fslResourceId: row.resourceId,
              fslDriverName: row.driverCleanName,
              motiveVehicleId: vehicle.id,
              motiveVehicleName: vehicle.name,
              motiveUnitNumber: FslTimeUtils.extractMotiveUnitNumber(
                vehicle.name,
              ),
              signal: signal,
              confidenceScore: confidence,
              gpsDistanceMeters: gpsMeters,
            ),
          );
        }
      }
    }

    // Greedy 1-to-1 assignment sorted by highest confidence score first
    candidateLinks.sort(
      (a, b) => b.confidenceScore.compareTo(a.confidenceScore),
    );
    final assignedDrivers = <String, DriverTruckLink>{};
    final assignedVehicles = <String, DriverTruckLink>{};

    for (final link in candidateLinks) {
      if (assignedDrivers.containsKey(link.fslResourceId)) continue;
      if (assignedVehicles.containsKey(link.motiveVehicleId)) continue;
      assignedDrivers[link.fslResourceId] = link;
      assignedVehicles[link.motiveVehicleId] = link;
    }

    final updatedRows = rows
        .map((r) => r.copyWith(linkedTruck: assignedDrivers[r.resourceId]))
        .toList();
    final updatedVehicles = vehicles
        .map((v) => v.copyWith(linkedFslDriver: assignedVehicles[v.id]))
        .toList();

    return (rows: updatedRows, vehicles: updatedVehicles);
  }
}
