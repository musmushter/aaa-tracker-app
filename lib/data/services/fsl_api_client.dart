import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../domain/use_cases/fsl_time_utils.dart';
import '../models/fsl_api_models.dart';
import 'auth_session_service.dart';

/// Direct HTTP client for Salesforce Field Service (FSL) Visualforce Remoting.
///
/// Replaces the Chrome CDP network-sniffing architecture with direct, lightweight
/// HTTP requests using the user's Salesforce session cookies.
class FslApiClient {
  FslApiClient({
    required this._authService,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final AuthSessionService _authService;
  final http.Client _http;
  int _tidCounter = 1;

  Map<String, String> _buildHeaders({bool isJsonPost = false}) {
    final base = _authService.fslBaseUrl;
    final uri = Uri.parse(base);
    final origin = '${uri.scheme}://${uri.host}';
    return <String, String>{
      'Cookie': _authService.fslCookieHeader,
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36',
      if (isJsonPost) 'Content-Type': 'application/json',
      if (isJsonPost) 'X-Requested-With': 'XMLHttpRequest',
      if (isJsonPost) 'X-User-Agent': 'Visualforce-Remoting',
      'Origin': origin,
      'Referer': '$base/apex/FSL__vf001_ServiceExpert',
    };
  }

  /// Fetches `/apex/FSL__vf001_ServiceExpert` and parses `RemotingProviderImpl({...})`
  /// to obtain `vid` and per-method `csrf` + `authorization` tokens.
  ///
  /// Also acts as a lightweight session keepalive when called periodically.
  Future<FslRemotingContext> fetchRemotingContext() async {
    final url = Uri.parse(
      '${_authService.fslBaseUrl}/apex/FSL__vf001_ServiceExpert',
    );
    var response = await _http
        .get(url, headers: _buildHeaders())
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw Exception(
        'FSL ServiceExpert returned HTTP ${response.statusCode}',
      );
    }

    var body = response.body;
    // If the session cookie is valid but gated by Salesforce's FSL_User_Login_Flow
    // (loginFlowOnly.apexp / lightningLoginFlow.apexp), complete the flow automatically
    // over pure HTTP and reload ServiceExpert.
    if (!body.contains('RemotingProviderImpl') &&
        (body.contains('loginFlowOnly.apexp') ||
            body.contains('lightningLoginFlow.apexp') ||
            body.contains('FSL_User_Login_Flow'))) {
      final completed = await _authService.completePendingFslLoginFlowIfNeeded();
      if (completed) {
        response = await _http
            .get(url, headers: _buildHeaders())
            .timeout(const Duration(seconds: 20));
        if (response.statusCode == 200) {
          body = response.body;
        }
      }
    }

    final matches = RegExp(
      r'RemotingProviderImpl\((\{.*?\})\)\)\s*;',
      dotAll: true,
    ).allMatches(body);
    if (matches.isEmpty) {
      throw Exception(
        'FSL session expired or RemotingProviderImpl not found in response.',
      );
    }

    String vid = '';
    final methods = <String, FslRemotingMethodToken>{};

    for (final m in matches) {
      try {
        final decoded = jsonDecode(m.group(1)!) as Map<String, dynamic>;
        final vf = (decoded['vf'] as Map<String, dynamic>?) ?? const {};
        final candidateVid = (vf['vid'] ?? '').toString();
        final actions =
            (decoded['actions'] as Map<String, dynamic>?) ?? const {};
        final gantt =
            (actions['FSL.ctrl001_Gantt'] as Map<String, dynamic>?) ?? const {};
        final msList = (gantt['ms'] as List<dynamic>?) ?? const [];

        if (msList.isNotEmpty) {
          if (candidateVid.isNotEmpty) {
            vid = candidateVid;
          }
          for (final item in msList) {
            if (item is Map<String, dynamic>) {
              final name = (item['name'] ?? '').toString();
              final csrf = (item['csrf'] ?? '').toString();
              final auth = (item['authorization'] ?? '').toString();
              if (name.isNotEmpty && csrf.isNotEmpty) {
                methods[name] = FslRemotingMethodToken(
                  name: name,
                  csrf: csrf,
                  authorization: auth,
                  ns: (item['ns'] ?? 'FSL').toString(),
                  ver: (item['ver'] is num)
                      ? (item['ver'] as num).toDouble()
                      : 66.0,
                );
              }
            }
          }
        }
      } catch (_) {}
    }

    if (vid.isEmpty || !methods.containsKey('getDelta')) {
      throw Exception('Incomplete FSL Remoting context (missing getDelta).');
    }

    final tzMatch = RegExp(
      r'''userTimeZone\s*=\s*['"]([^'"]+)['"]''',
    ).firstMatch(body);
    final discoveredTz = tzMatch?.group(1)?.trim();
    if (discoveredTz != null && discoveredTz.isNotEmpty) {
      FslTimeUtils.setAccountTimeZone(discoveredTz);
    }

    return FslRemotingContext(
      vid: vid,
      methods: methods,
      fetchedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
      userTimeZone: FslTimeUtils.accountTimeZoneId,
    );
  }

  /// Calls `FSL.ctrl001_Gantt.getUserSettings` to discover the user's active
  /// ServiceTerritory IDs (`locations` and `Toggled_Territories__c`).
  Future<List<String>> fetchUserTerritoryLocations(
    FslRemotingContext ctx,
  ) async {
    final token = ctx.tokenFor('getUserSettings');
    if (token == null) {
      throw Exception('Missing getUserSettings token in FSL Remoting context');
    }

    final result = await _invokeApexRemote(
      ctx: ctx,
      token: token,
      data: const [],
    );

    final discovered = <String>{};

    void addFromList(dynamic list) {
      if (list is List) {
        for (final item in list) {
          final s = unwrapSfValue(item)?.toString().trim() ?? '';
          if (s.isNotEmpty) discovered.add(s);
        }
      }
    }

    addFromList(result['locations']);

    final rawUserSettings = unwrapSfValue(result['userSettings']);
    Map<String, dynamic>? usMap;
    if (rawUserSettings is String && rawUserSettings.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(rawUserSettings);
        if (decoded is Map<String, dynamic>) {
          usMap = decoded;
        }
      } catch (_) {}
    } else if (rawUserSettings is Map) {
      usMap = Map<String, dynamic>.from(rawUserSettings);
    }

    if (usMap != null) {
      addFromList(usMap['locations']);
      final toggledRaw = usMap['Toggled_Territories__c'];
      if (toggledRaw is String && toggledRaw.trim().startsWith('{')) {
        try {
          final toggledMap = jsonDecode(toggledRaw);
          if (toggledMap is Map) {
            for (final entry in toggledMap.entries) {
              if (entry.value == true) {
                final k = entry.key.toString().trim();
                if (k.isNotEmpty) discovered.add(k);
              }
            }
          }
        } catch (_) {}
      }
    }

    return discovered.toList();
  }

  /// Calls `FSL.ctrl001_Gantt.GetResourcesAndTerritories` with `[locations, true, false]`
  /// to load the full ServiceResource roster (names, phones, territories, and last known GPS).
  Future<List<FslResourceDto>> fetchResourcesAndTerritories({
    required FslRemotingContext ctx,
    required List<String> locations,
  }) async {
    final token = ctx.tokenFor('GetResourcesAndTerritories');
    if (token == null || locations.isEmpty) {
      return const [];
    }

    final result = await _invokeApexRemote(
      ctx: ctx,
      token: token,
      data: <dynamic>[locations, true, false],
    );

    final territoriesById = <String, String>{};
    final rawTerritories = unwrapSfValue(result['territories']);
    if (rawTerritories is List) {
      for (final item in rawTerritories) {
        final u = unwrapSfValue(item);
        if (u is Map) {
          final tid = unwrapSfValue(u['Id'] ?? u['id'])?.toString().trim() ?? '';
          final tname =
              unwrapSfValue(u['Name'] ?? u['name'])?.toString().trim() ?? '';
          if (tid.isNotEmpty && tname.isNotEmpty) {
            territoriesById[tid] = tname;
          }
        }
      }
    }

    final resources = <FslResourceDto>[];
    final rawResources = unwrapSfValue(result['resources']);
    if (rawResources is List) {
      for (final item in rawResources) {
        final u = unwrapSfValue(item);
        if (u is Map) {
          final map = Map<String, dynamic>.from(u);
          if (map['ServiceTerritory.Name'] == null &&
              territoriesById.length == 1) {
            map['ServiceTerritory.Name'] = territoriesById.values.first;
          }
          final dto = FslResourceDto.fromJson(map);
          if (dto.id.isNotEmpty) {
            resources.add(dto);
          }
        }
      }
    }
    return resources;
  }

  /// Calls `FSL.ctrl001_Gantt.getDelta` with `[lastUpdateTimeMs, locations, minDateMs, maxDateMs]`.
  ///
  /// Passing `lastUpdateTimeMs = nowMs - 12h` on startup loads the full shift's
  /// appointments and active driver GPS positions in a single request.
  Future<
    ({
      int serverUpdateTimeMs,
      List<FslServiceAppointmentDto> appointments,
      List<FslResourceDto> resources,
      List<String> deletedAppointmentIds,
    })
  >
  fetchDelta({
    required FslRemotingContext ctx,
    required int lastUpdateTimeMs,
    required List<String> locations,
    required int minDateMs,
    required int maxDateMs,
  }) async {
    final token = ctx.tokenFor('getDelta');
    if (token == null) {
      throw Exception('Missing getDelta token in FSL Remoting context');
    }

    final result = await _invokeApexRemote(
      ctx: ctx,
      token: token,
      data: <dynamic>[lastUpdateTimeMs, locations, minDateMs, maxDateMs],
    );

    final rawUpdateTime = unwrapSfValue(result['updateTime']);
    final serverUpdateTimeMs = (rawUpdateTime is num)
        ? rawUpdateTime.toInt()
        : DateTime.now().millisecondsSinceEpoch;

    final rawServices = unwrapSfValue(
      result['updatedGanttServices'] ??
          result['UpdatedServices'] ??
          result['Services'] ??
          const [],
    );

    final appointments = <FslServiceAppointmentDto>[];
    if (rawServices is List) {
      for (final item in rawServices) {
        final u = unwrapSfValue(item);
        if (u is Map) {
          final dto = FslServiceAppointmentDto.fromJson(
            Map<String, dynamic>.from(u),
          );
          if (dto.id.isNotEmpty) {
            appointments.add(dto);
          }
        }
      }
    }

    final resources = <FslResourceDto>[];
    final rawPositions = unwrapSfValue(
      result['updatedLivePositions'] ??
          result['UpdatedResources'] ??
          result['Resources'],
    );
    if (rawPositions is Map) {
      for (final entry in rawPositions.entries) {
        final rid = entry.key.toString();
        final pos = unwrapSfValue(entry.value);
        if (pos is Map) {
          final map = Map<String, dynamic>.from(pos);
          map['Id'] ??= rid;
          final dto = FslResourceDto.fromJson(map);
          if (dto.id.isNotEmpty) {
            resources.add(dto);
          }
        }
      }
    } else if (rawPositions is List) {
      for (final item in rawPositions) {
        final u = unwrapSfValue(item);
        if (u is Map) {
          final dto = FslResourceDto.fromJson(Map<String, dynamic>.from(u));
          if (dto.id.isNotEmpty) {
            resources.add(dto);
          }
        }
      }
    }

    final deletedIds = <String>[];
    final rawDeleted = unwrapSfValue(result['deletedGanttServices']);
    if (rawDeleted is List) {
      for (final item in rawDeleted) {
        final id = unwrapSfValue(item);
        if (id is String && id.trim().isNotEmpty) {
          deletedIds.add(id.trim());
        }
      }
    }

    return (
      serverUpdateTimeMs: serverUpdateTimeMs,
      appointments: appointments,
      resources: resources,
      deletedAppointmentIds: deletedIds,
    );
  }

  Future<Map<String, dynamic>> _invokeApexRemote({
    required FslRemotingContext ctx,
    required FslRemotingMethodToken token,
    required List<dynamic> data,
  }) async {
    final url = Uri.parse('${_authService.fslBaseUrl}/apexremote');
    final payload = <String, dynamic>{
      'action': 'FSL.ctrl001_Gantt',
      'method': token.name,
      'data': data,
      'type': 'rpc',
      'tid': _tidCounter++,
      'ctx': <String, dynamic>{
        'csrf': token.csrf,
        'vid': ctx.vid,
        'ns': token.ns,
        'ver': token.ver.toInt(),
        'authorization': token.authorization,
      },
    };

    final response = await _http
        .post(
          url,
          headers: _buildHeaders(isJsonPost: true),
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw Exception(
        'FSL apexremote (${token.name}) failed with HTTP ${response.statusCode}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is List && decoded.isNotEmpty) {
      final first = decoded.first;
      if (first is Map<String, dynamic>) {
        final statusCode = first['statusCode'] ?? 200;
        if (statusCode != 200) {
          final msg = first['message'] ?? 'Unknown Apex error';
          throw Exception('FSL ${token.name} error ($statusCode): $msg');
        }
        final res = resolveSfRemotingRefs(first['result']);
        if (res is Map<String, dynamic>) {
          return res;
        }
        if (res is Map) {
          return Map<String, dynamic>.from(res);
        }
      }
    }
    return const {};
  }

  /// Fetches a Visualforce chatter/lightbox page directly (`vf0996_workorderchatter`,
  /// `vf0993_servicechatter`, `vf0999_workorderlightbox`, or `vf002_serviceexpertlightboxform`).
  Future<String> fetchVisualforcePage(String pageName, String recordId) async {
    final url = Uri.parse(
      '${_authService.fslBaseUrl}/apex/$pageName?id=$recordId',
    );
    final response = await _http
        .get(url, headers: _buildHeaders())
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('Failed to load $pageName ($recordId): ${response.statusCode}');
    }
    return response.body;
  }
}
