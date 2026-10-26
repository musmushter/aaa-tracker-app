import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../domain/models/motive_vehicle.dart';
import '../models/motive_api_models.dart';
import 'snapshot_storage_service.dart';

/// Direct HTTP client for Motive API (`https://api.keeptruckin.com`).
///
/// Supports multi-organization fleets, dynamic group discovery, live hardware
/// dashcam wakeup (`/api/w2/live_checkin/refresh`), and bounded snapshot saving.
class MotiveApiClient {
  MotiveApiClient({
    required this._snapshotStorage,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  static const String _baseApiUrl = 'https://api.keeptruckin.com';

  final SnapshotStorageService _snapshotStorage;
  final http.Client _http;
  final Map<String, Map<int, String>> _groupNamesCacheByToken = {};

  Map<String, String> _buildHeaders(
    MotiveAccountSession account, {
    bool isJsonPost = false,
  }) {
    return <String, String>{
      'x-web-user-auth': account.authToken,
      if (account.organizationId.isNotEmpty)
        'x-web-company-id': account.organizationId,
      'Accept': 'application/json, text/plain, */*',
      if (isJsonPost) 'Content-Type': 'application/json',
      'Origin': 'https://app.gomotive.com',
      'Referer': 'https://app.gomotive.com/',
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36',
    };
  }

  /// Calls `GET /api/w2/sessions/validate` to dynamically discover the user's
  /// group IDs and names (`user.groups`) with zero hardcoded `GROUP_MAP`.
  Future<Map<int, String>> _resolveDynamicGroupNames(
    MotiveAccountSession account,
  ) async {
    final cached = _groupNamesCacheByToken[account.authToken];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    final map = <int, String>{};
    try {
      final url = Uri.parse('$_baseApiUrl/api/w2/sessions/validate');
      final response = await _http
          .get(url, headers: _buildHeaders(account))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          final user = decoded['user'];
          if (user is Map<String, dynamic>) {
            final groups = user['groups'];
            if (groups is List) {
              for (final item in groups) {
                if (item is Map<String, dynamic>) {
                  final grp = (item['group'] is Map<String, dynamic>)
                      ? item['group'] as Map<String, dynamic>
                      : item;
                  final id = grp['id'];
                  final name = grp['name']?.toString().trim();
                  if (id is int && name != null && name.isNotEmpty) {
                    map[id] = name;
                  }
                }
              }
            }
          }
        }
      }
    } catch (_) {}

    if (map.isNotEmpty) {
      _groupNamesCacheByToken[account.authToken] = map;
    }
    return map;
  }

  /// Fetches all vehicles for a single [MotiveAccountSession], dynamically
  /// discovering group names and hydrating any cached snapshots on disk.
  Future<List<MotiveVehicle>> fetchVehiclesForAccount(
    MotiveAccountSession account,
  ) async {
    final dynamicGroupNames = await _resolveDynamicGroupNames(account);
    final results = <MotiveVehicle>[];
    final seenIds = <String>{};
    int page = 1;

    while (page <= 10) {
      final url = Uri.parse(
        '$_baseApiUrl/api/w3/vehicles?page_no=$page&per_page=100',
      );
      final response = await _http
          .get(url, headers: _buildHeaders(account))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception(
          'Motive /api/w3/vehicles (${account.organizationName}) returned HTTP ${response.statusCode}',
        );
      }

      final decoded = jsonDecode(response.body);
      final rawList = (decoded is Map<String, dynamic>)
          ? (decoded['vehicles'] as List<dynamic>? ?? const [])
          : (decoded is List ? decoded : const []);

      if (rawList.isEmpty) break;

      for (final item in rawList) {
        if (item is Map<String, dynamic>) {
          final parsed = MotiveVehicleParser.fromApiJson(
            item,
            account: account,
            dynamicGroupNamesById: dynamicGroupNames,
          );
          if (parsed.id.isNotEmpty && seenIds.add(parsed.id)) {
            final existingSnaps = await _snapshotStorage.getExistingSnapshots(
              parsed.id,
            );
            results.add(
              parsed.copyWith(
                driverCameraPath: existingSnaps.driverPath,
                roadCameraPath: existingSnaps.roadPath,
                cameraPathsByAngle: existingSnaps.byAngle,
                lastRefreshedEpochMs: existingSnaps.lastModifiedEpochMs,
                cameraStatusText: existingSnaps.byAngle.isNotEmpty
                    ? 'Cached'
                    : parsed.cameraStatusText,
              ),
            );
          }
        }
      }

      if (rawList.length < 100) break;
      page++;
    }

    return results;
  }

  /// Triggers a live hardware dashcam refresh for [vehicle] and polls `/follow`
  /// until a fresh snapshot (`< 3 min` old) is received, saving all available
  /// camera angles (`driver`, `road`, `front_narrow`, `rear`, `side_left`,
  /// `side_right`) via [SnapshotStorageService].
  Future<MotiveVehicle> refreshVehicleCamera({
    required MotiveVehicle vehicle,
    required MotiveAccountSession account,
    Duration pollTimeout = const Duration(seconds: 24),
  }) async {
    String? eldIdentifier = vehicle.eldIdentifier;
    bool vgPoweredOff = vehicle.isPoweredOff;

    // 1. Resolve eld_identifier if not yet cached
    if (eldIdentifier == null || eldIdentifier.isEmpty) {
      final detailUrl = Uri.parse('$_baseApiUrl/api/w3/vehicles/${vehicle.id}');
      try {
        final detailResp = await _http
            .get(detailUrl, headers: _buildHeaders(account))
            .timeout(const Duration(seconds: 10));
        if (detailResp.statusCode == 200) {
          final detailJson = jsonDecode(detailResp.body);
          final vObj = (detailJson is Map<String, dynamic>)
              ? (detailJson['vehicle'] as Map<String, dynamic>? ?? detailJson)
              : const <String, dynamic>{};
          final dashInfo = (vObj['dashcam_info'] is Map<String, dynamic>)
              ? vObj['dashcam_info'] as Map<String, dynamic>
              : null;
          vgPoweredOff =
              vObj['vg_powered_off'] == true ||
              dashInfo?['health_sub_status_key'] == 'vg_powered_off';
          final eldDev = vObj['eld_device'];
          if (eldDev is Map<String, dynamic>) {
            eldIdentifier =
                (eldDev['identifier'] ?? eldDev['eld_identifier'])?.toString();
          }
        }
      } catch (_) {}
    }

    if (vgPoweredOff) {
      return vehicle.copyWith(
        isPoweredOff: true,
        offlineReason: 'Vehicle gateway powered off',
        cameraStatusText: 'Powered Off',
      );
    }

    // 2. Trigger live checkin wakeup if eldIdentifier is present
    if (eldIdentifier != null && eldIdentifier.isNotEmpty) {
      final checkinUrl = Uri.parse('$_baseApiUrl/api/w2/live_checkin/refresh');
      try {
        await _http
            .post(
              checkinUrl,
              headers: _buildHeaders(account, isJsonPost: true),
              body: jsonEncode(<String, dynamic>{
                'eld_identifier': eldIdentifier,
                'device_ids': const <int>[],
              }),
            )
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        // Proceed to poll /follow even if checkin returns non-200
      }
    }

    // 3. Poll /api/w3/vehicles/{id}/follow?include_groups=true for fresh camera frames
    final followUrl = Uri.parse(
      '$_baseApiUrl/api/w3/vehicles/${vehicle.id}/follow?include_groups=true',
    );
    final deadline = DateTime.now().add(pollTimeout);

    final bestUrlsByAngle = <String, String>{};
    DateTime? latestFrameTime;

    while (DateTime.now().isBefore(deadline)) {
      try {
        final followResp = await _http
            .get(followUrl, headers: _buildHeaders(account))
            .timeout(const Duration(seconds: 10));

        if (followResp.statusCode == 200) {
          final followJson = jsonDecode(followResp.body);
          if (followJson is Map<String, dynamic>) {
            final vObj =
                (followJson['travel_group'] is Map<String, dynamic> &&
                    (followJson['travel_group'] as Map)['vehicle']
                        is Map<String, dynamic>)
                ? (followJson['travel_group'] as Map)['vehicle']
                      as Map<String, dynamic>
                : (followJson['vehicle'] as Map<String, dynamic>? ?? followJson);

            final dashInfo = (vObj['dashcam_info'] is Map<String, dynamic>)
                ? vObj['dashcam_info'] as Map<String, dynamic>
                : null;
            if (vObj['vg_powered_off'] == true ||
                dashInfo?['health_sub_status_key'] == 'vg_powered_off') {
              return vehicle.copyWith(
                eldIdentifier: eldIdentifier,
                isPoweredOff: true,
                offlineReason: 'Vehicle gateway powered off',
                cameraStatusText: 'Powered Off',
              );
            }

            final extracted = _extractCameraUrlsAndTimestamp(followJson, vObj);
            bestUrlsByAngle.addAll(extracted.urlsByAngle);
            if (extracted.receivedTime != null) {
              latestFrameTime = extracted.receivedTime;
              final ageSec = DateTime.now()
                  .difference(extracted.receivedTime!)
                  .inSeconds;
              if (ageSec <= 180 && bestUrlsByAngle.isNotEmpty) {
                break;
              }
            }
          }
        }
      } catch (_) {}

      await Future<void>.delayed(const Duration(seconds: 3));
    }

    final savedPathsByAngle = <String, String>{...vehicle.cameraPathsByAngle};

    if (bestUrlsByAngle.isNotEmpty) {
      await Future.wait(
        bestUrlsByAngle.entries.map((entry) async {
          try {
            final imgResp = await _http
                .get(Uri.parse(entry.value))
                .timeout(const Duration(seconds: 12));
            if (imgResp.statusCode == 200 && imgResp.bodyBytes.isNotEmpty) {
              final savedPath = await _snapshotStorage.saveSnapshot(
                vehicleId: vehicle.id,
                cameraAngle: entry.key,
                bytes: imgResp.bodyBytes,
              );
              savedPathsByAngle[entry.key] = savedPath;
            }
          } catch (_) {
            // Keep existing cached snapshot if one angle download fails
          }
        }),
      );
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final frameMs = latestFrameTime?.millisecondsSinceEpoch;
    final isFresh = frameMs != null && ((nowMs - frameMs) / 60000.0) <= 3.5;

    if (savedPathsByAngle.isEmpty) {
      final nextTimeouts = vehicle.consecutiveTimeouts + 1;
      final markOffline = nextTimeouts >= 3;
      return vehicle.copyWith(
        eldIdentifier: eldIdentifier,
        consecutiveTimeouts: nextTimeouts,
        isPoweredOff: markOffline,
        offlineReason: markOffline
            ? 'Unresponsive after $nextTimeouts refresh attempts'
            : vehicle.offlineReason,
        cameraStatusText: markOffline ? 'Powered Off' : 'Timed Out',
      );
    }

    return vehicle.copyWith(
      eldIdentifier: eldIdentifier,
      driverCameraPath: savedPathsByAngle['driver'],
      roadCameraPath: savedPathsByAngle['road'],
      cameraPathsByAngle: savedPathsByAngle,
      lastRefreshedEpochMs: frameMs ?? nowMs,
      cameraStatusText: isFresh ? 'Live' : 'Captured',
      consecutiveTimeouts: 0,
      isPoweredOff: false,
      offlineReason: '',
    );
  }

  ({Map<String, String> urlsByAngle, DateTime? receivedTime})
  _extractCameraUrlsAndTimestamp(
    Map<String, dynamic> rootJson,
    Map<String, dynamic> vObj,
  ) {
    final urlsByAngle = <String, String>{};
    DateTime? latestTime;

    void parseIsoTimestamp(dynamic rawTs) {
      if (rawTs == null) return;
      final dt = DateTime.tryParse(rawTs.toString());
      if (dt != null && (latestTime == null || dt.isAfter(latestTime!))) {
        latestTime = dt;
      }
    }

    // 1. Primary Motive `/follow` structure: `image_check.last_image_metadata`
    final imageCheck =
        (vObj['image_check'] is Map<String, dynamic>)
            ? vObj['image_check'] as Map<String, dynamic>
            : ((rootJson['travel_group'] is Map<String, dynamic> &&
                      ((rootJson['travel_group'] as Map)['vehicle'] is Map) &&
                      (((rootJson['travel_group'] as Map)['vehicle']
                              as Map)['image_check']
                          is Map<String, dynamic>))
                  ? (((rootJson['travel_group'] as Map)['vehicle']
                            as Map)['image_check']
                        as Map<String, dynamic>)
                  : null);

    if (imageCheck != null &&
        imageCheck['last_image_metadata'] is Map<String, dynamic>) {
      final md = imageCheck['last_image_metadata'] as Map<String, dynamic>;
      parseIsoTimestamp(md['image_received_time']);

      const angleFieldMap = <String, String>{
        'driver': 'driver_facing_image_url',
        'road': 'front_facing_image_url',
        'front_narrow': 'front_narrow_facing_image_url',
        'rear': 'rear_facing_image_url',
        'side_left': 'side_left_image_url',
        'side_right': 'side_right_image_url',
      };

      for (final entry in angleFieldMap.entries) {
        final rawUrl = md[entry.value]?.toString();
        if (rawUrl != null && rawUrl.startsWith('http')) {
          urlsByAngle[entry.key] = rawUrl;
        }
      }
    }

    // 2. Fallback container structures (`camera_images`, `live_images`, `camera_device.images`)
    void inspectImagesContainer(dynamic container) {
      if (container is Map<String, dynamic>) {
        for (final entry in container.entries) {
          final k = entry.key.toLowerCase();
          final val = entry.value;
          if (val is Map<String, dynamic>) {
            final url = (val['url'] ?? val['image_url'] ?? val['s3_url'])
                ?.toString();
            parseIsoTimestamp(
              val['image_received_time'] ??
                  val['received_at'] ??
                  val['timestamp'],
            );
            if (url != null && url.startsWith('http')) {
              if (k.contains('driver') || k.contains('inward')) {
                urlsByAngle.putIfAbsent('driver', () => url);
              } else if (k.contains('narrow')) {
                urlsByAngle.putIfAbsent('front_narrow', () => url);
              } else if (k.contains('front') ||
                  k.contains('road') ||
                  k.contains('outward')) {
                urlsByAngle.putIfAbsent('road', () => url);
              } else if (k.contains('rear') || k.contains('back')) {
                urlsByAngle.putIfAbsent('rear', () => url);
              } else if (k.contains('left')) {
                urlsByAngle.putIfAbsent('side_left', () => url);
              } else if (k.contains('right')) {
                urlsByAngle.putIfAbsent('side_right', () => url);
              }
            }
          }
        }
      }
    }

    inspectImagesContainer(vObj['camera_images']);
    inspectImagesContainer(vObj['live_images']);
    if (vObj['camera_device'] is Map<String, dynamic>) {
      inspectImagesContainer(
        (vObj['camera_device'] as Map<String, dynamic>)['images'],
      );
    }

    return (urlsByAngle: urlsByAngle, receivedTime: latestTime);
  }
}
