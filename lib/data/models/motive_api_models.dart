import '../../domain/models/motive_vehicle.dart';

/// Represents an authenticated Motive organization session.
///
/// Discovered dynamically from Motive's API or user login—no hardcoded user IDs,
/// company IDs, or group maps.
class MotiveAccountSession {
  const MotiveAccountSession({
    required this.organizationId,
    required this.organizationName,
    required this.authToken,
  });

  factory MotiveAccountSession.fromJson(Map<String, dynamic> json) {
    return MotiveAccountSession(
      organizationId: (json['organizationId'] ?? json['org_id'] ?? '')
          .toString(),
      organizationName:
          (json['organizationName'] ?? json['org_name'] ?? 'Motive Org')
              .toString(),
      authToken: (json['authToken'] ?? json['token'] ?? '').toString(),
    );
  }

  final String organizationId;
  final String organizationName;
  final String authToken;

  Map<String, dynamic> toJson() => {
    'organizationId': organizationId,
    'organizationName': organizationName,
    'authToken': authToken,
  };
}

/// Parses a raw vehicle JSON item from `https://api.keeptruckin.com/api/w3/vehicles`
/// into a clean [MotiveVehicle] domain model, resolving group names dynamically.
class MotiveVehicleParser {
  static MotiveVehicle fromApiJson(
    Map<String, dynamic> rawItem, {
    required MotiveAccountSession account,
    Map<int, String> dynamicGroupNamesById = const {},
  }) {
    final v = (rawItem['vehicle'] is Map<String, dynamic>)
        ? rawItem['vehicle'] as Map<String, dynamic>
        : rawItem;

    final id = (v['id'] ?? '').toString();
    final name = (v['number'] ?? v['name'] ?? id).toString().trim();

    final make = (v['make'] ?? '').toString().trim();
    final model = (v['model'] ?? '').toString().trim();
    final year = (v['year'] ?? '').toString().trim();
    final mmy = [make, model, year].where((s) => s.isNotEmpty).join(' ');

    // Extract dynamic driver name
    String driverName = 'Unassigned';
    final currentDriver = v['current_driver'] ?? v['permanent_driver'];
    if (currentDriver is Map<String, dynamic>) {
      final fn = (currentDriver['first_name'] ?? '').toString().trim();
      final ln = (currentDriver['last_name'] ?? '').toString().trim();
      final combined = '$fn $ln'.trim();
      if (combined.isNotEmpty) {
        driverName = combined;
      }
    }

    // Extract dynamic association/group name from `groups` or `group_ids`
    String groupName = 'Unassigned';
    final groupsList = v['groups'];
    if (groupsList is List && groupsList.isNotEmpty) {
      final firstGrp = groupsList.first;
      if (firstGrp is Map<String, dynamic>) {
        final gName = (firstGrp['name'] ?? firstGrp['title'] ?? '')
            .toString()
            .trim();
        if (gName.isNotEmpty) groupName = gName;
      }
    }
    if (groupName == 'Unassigned') {
      final groupIds = v['group_ids'];
      if (groupIds is List && groupIds.isNotEmpty) {
        for (final rawGid in groupIds) {
          final gid = rawGid is int
              ? rawGid
              : int.tryParse(rawGid.toString());
          if (gid != null && dynamicGroupNamesById.containsKey(gid)) {
            groupName = dynamicGroupNamesById[gid]!;
            break;
          }
        }
      }
    }
    // Fallback inference from vehicle naming convention if group wasn't tagged
    if (groupName == 'Unassigned') {
      final upperName = name.toUpperCase();
      if (upperName.contains('ALL AMERICAN') ||
          upperName.startsWith('LS-TRUCK') ||
          upperName.startsWith('FB-TRUCK') ||
          upperName.startsWith('WL-TRUCK')) {
        groupName = 'ALL AMERICAN';
      } else if (upperName.contains('/BMW') || upperName.contains('-BMW')) {
        groupName = 'BMW';
      } else if (upperName.contains('HOUSTON TOWING') ||
          upperName.contains('(HT)')) {
        groupName = 'HOUSTON TOWING';
      }
    }

    // Extract telematics & motion state (supports both `current_state` from /api/w3/vehicles
    // and `current_location`)
    final loc = (v['current_location'] is Map<String, dynamic>)
        ? v['current_location'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final currentState = (v['current_state'] is Map<String, dynamic>)
        ? v['current_state'] as Map<String, dynamic>
        : const <String, dynamic>{};

    double speedMph = 0.0;
    final rawKph = currentState['ground_speed_kph'];
    if (rawKph != null) {
      final kph = rawKph is num
          ? rawKph.toDouble()
          : (double.tryParse(rawKph.toString()) ?? 0.0);
      speedMph = kph * 0.621371;
    } else {
      final rawSpeed = loc['speed'] ?? v['speed'] ?? 0;
      speedMph = rawSpeed is num
          ? rawSpeed.toDouble()
          : (double.tryParse(rawSpeed.toString()) ?? 0.0);
    }

    final rawStatus =
        (currentState['entity_state'] ??
                loc['status'] ??
                v['motion_state'] ??
                v['status'] ??
                '')
            .toString();
    final statusLower = rawStatus.toLowerCase();

    VehicleMotionCategory motionCat;
    String statusText;
    if (speedMph > 2.0 ||
        statusLower.contains('driving') ||
        statusLower.contains('moving') ||
        statusLower.contains('transit')) {
      motionCat = VehicleMotionCategory.transit;
      final roundedSpeed = double.parse(speedMph.toStringAsFixed(1));
      statusText = roundedSpeed > 0
          ? 'In Transit ($roundedSpeed mph)'
          : 'In Transit';
    } else if (statusLower.contains('idle') || statusLower.contains('idling')) {
      motionCat = VehicleMotionCategory.idle;
      statusText = 'Idling';
    } else {
      motionCat = VehicleMotionCategory.stationary;
      statusText = 'Stationary';
    }

    final lat = (loc['lat'] ?? currentState['lat']) is num
        ? ((loc['lat'] ?? currentState['lat']) as num).toDouble()
        : double.tryParse(
            (loc['lat'] ?? currentState['lat'] ?? '').toString(),
          );
    final lon = (loc['lon'] ?? currentState['lon']) is num
        ? ((loc['lon'] ?? currentState['lon']) as num).toDouble()
        : double.tryParse(
            (loc['lon'] ?? currentState['lon'] ?? '').toString(),
          );
    final locatedAtIso =
        (loc['located_at'] ?? currentState['located_at'])?.toString();

    // Camera hardware & ELD info
    final eldDev = (v['eld_device'] is Map<String, dynamic>)
        ? v['eld_device'] as Map<String, dynamic>
        : null;
    final rawEldId = v['eld_device_id'] ?? eldDev?['id'];
    final eldId = rawEldId is int
        ? rawEldId
        : int.tryParse((rawEldId ?? '').toString());
    final eldIdentifier =
        (eldDev?['identifier'] ?? eldDev?['eld_identifier'])?.toString();

    final dashInfo = (v['dashcam_info'] is Map<String, dynamic>)
        ? v['dashcam_info'] as Map<String, dynamic>
        : null;
    final hasCamera =
        v['camera'] != null ||
        dashInfo != null ||
        v['camera_device'] != null ||
        v['smart_dashcam'] != null ||
        eldId != null ||
        v['has_camera'] == true;
    final vgPoweredOff =
        v['vg_powered_off'] == true ||
        dashInfo?['health_sub_status_key'] == 'vg_powered_off';

    return MotiveVehicle(
      id: id,
      name: name,
      organizationId: account.organizationId,
      organizationName: account.organizationName,
      associationGroup: groupName,
      assignedDriverName: driverName,
      makeModelYear: mmy,
      statusText: statusText,
      motionCategory: motionCat,
      speedMph: double.parse(speedMph.toStringAsFixed(1)),
      hasCamera: hasCamera,
      isPoweredOff: vgPoweredOff,
      offlineReason: vgPoweredOff ? 'Vehicle gateway powered off' : null,
      eldDeviceId: eldId,
      eldIdentifier: eldIdentifier,
      latitude: lat,
      longitude: lon,
      locatedAtIso: locatedAtIso,
    );
  }
}
