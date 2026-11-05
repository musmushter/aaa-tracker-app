import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/models/cleared_call.dart';
import '../../domain/models/dispatch_alert.dart';
import '../../domain/models/dispatch_row.dart';
import '../../domain/use_cases/fsl_chatter_parser.dart';
import '../../domain/use_cases/fsl_time_utils.dart';
import '../models/fsl_api_models.dart';
import '../services/fsl_api_client.dart';

class _GpsSample {
  const _GpsSample(this.epochMs, this.lat, this.lon);
  final int epochMs;
  final double lat;
  final double lon;
}

/// Single source of truth for Salesforce FSL Dispatch Tracker state.
///
/// Implements:
/// - Smart Remoting context & Central day-window management (zero calendar drift).
/// - In-memory resource & appointment state (no `roster.json` disk pollution).
/// - First-service & 2-leg tow pair ("Immediately Follow") selection.
/// - Rework #1: Reassigned-driver ETA hiding + Same-driver Placeholder/Unrealistic ETA detection.
/// - Rework #2: Fast parallel Direct HTTP enrichment for Member Names & SA Chatter feeds
///   with SharedPreferences disk caching for instant startup population.
class FslRepository {
  FslRepository({required this._apiClient});

  static const String _prefsCacheKey = 'fsl_enrichment_cache_v1';

  final FslApiClient _apiClient;

  FslRemotingContext? _remotingCtx;
  List<String> _territoryLocations = const [];
  int? _lastUpdateTimeMs;
  bool _diskCacheLoaded = false;

  final Map<String, FslServiceAppointmentDto> _appointmentsById = {};
  final Map<String, FslResourceDto> _resourcesById = {};
  final Map<String, List<_GpsSample>> _gpsHistoryByResource = {};
  final Map<String, int> _statusSinceEpochMsBySa = {};
  final Map<String, String> _lastStatusBySa = {};
  final Map<String, int> _arrivedAtEpochMsBySa = {};
  final Map<String, bool> _arrivedLiveBySa = {};
  final Map<String, int> _clearedAtEpochMsBySa = {};

  /// Caches for Chatter / Lightbox enrichment
  final Map<String, ParsedChatterEta> _etasByRecordId = {};
  final Map<String, int> _lastEtaFetchMs = {};
  final Map<String, ParsedSaFeedTimes> _saFeedTimesBySaId = {};
  final Map<String, int> _lastSaFeedFetchMs = {};
  final Map<String, ParsedWorkOrderLightbox> _woCacheByParentId = {};
  final Map<String, int> _lastWoFetchMs = {};
  final Map<String, String> _dropoffCacheBySaId = {};
  final Map<String, List<String>> _kmiByParentId = {};

  /// Tracks user "Called Back" checkmarks by `ClearedCall.uniqueKey` (`callId_driverName`)
  /// or `callId`.
  final Set<String> _calledBackKeys = {};

  List<ClearedCall> _latestClearedCalls = const [];

  static const Set<String> _activeStatuses = {
    'Dispatched',
    'En Route',
    'On Location',
    'Tow Loaded',
    'In Tow',
    'Scheduled',
    'Spotted',
  };

  static const Set<String> _arrivedStatuses = {
    'On Location',
    'Tow Loaded',
    'In Tow',
  };

  static const Set<String> _completedStatuses = {
    'Cleared',
    'Complete',
    'Tow Complete',
    'Completed',
  };

  static const Set<String> _cancelledStatuses = {
    'Canceled',
    'Cancelled',
    'Cannot Complete',
    'Unable to Complete',
  };

  static bool isTerminalStatus(String status) =>
      _completedStatuses.contains(status) || _cancelledStatuses.contains(status);

  static bool isCancelledStatus(String status) =>
      _cancelledStatuses.contains(status);

  List<ClearedCall> get clearedCalls => _latestClearedCalls;

  /// Loads persisted Work Order Lightbox, SA Chatter feed timestamps, and
  /// Called Back checkmarks from local storage so the Callback Log populates
  /// immediately on app launch.
  Future<void> loadDiskCache() async {
    if (_diskCacheLoaded) return;
    _diskCacheLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsCacheKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;

      final woMap = decoded['woCache'];
      if (woMap is Map) {
        for (final entry in woMap.entries) {
          if (entry.value is Map) {
            _woCacheByParentId[entry.key.toString()] =
                ParsedWorkOrderLightbox.fromJson(
                  Map<String, dynamic>.from(entry.value as Map),
                );
          }
        }
      }

      final saMap = decoded['saFeedCache'];
      if (saMap is Map) {
        for (final entry in saMap.entries) {
          if (entry.value is Map) {
            _saFeedTimesBySaId[entry.key.toString()] =
                ParsedSaFeedTimes.fromJson(
                  Map<String, dynamic>.from(entry.value as Map),
                );
          }
        }
      }

      final cbList = decoded['calledBackKeys'];
      if (cbList is List) {
        for (final item in cbList) {
          if (item is String && item.isNotEmpty) {
            _calledBackKeys.add(item);
          }
        }
      }

      final resMap = decoded['resourceRoster'];
      if (resMap is Map) {
        for (final entry in resMap.entries) {
          final rid = entry.key.toString();
          final val = entry.value;
          if (rid.isNotEmpty && val is Map) {
            final name = (val['name'] ?? '').toString().trim();
            final territory = (val['territory'] ?? '').toString().trim();
            if (name.isNotEmpty) {
              final existing = _resourcesById[rid];
              _resourcesById[rid] = FslResourceDto(
                id: rid,
                name: existing != null && existing.name.trim().isNotEmpty
                    ? existing.name
                    : name,
                territoryName:
                    existing?.territoryName ??
                    (territory.isNotEmpty ? territory : null),
                latitude: existing?.latitude,
                longitude: existing?.longitude,
                lastLocationWallMs: existing?.lastLocationWallMs,
              );
            }
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _saveDiskCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final woEntries = _woCacheByParentId.entries.toList();
      final trimmedWo = woEntries.length > 600
          ? woEntries.sublist(woEntries.length - 600)
          : woEntries;

      final saEntries = _saFeedTimesBySaId.entries.toList();
      final trimmedSa = saEntries.length > 800
          ? saEntries.sublist(saEntries.length - 800)
          : saEntries;

      final payload = <String, dynamic>{
        'woCache': {
          for (final e in trimmedWo) e.key: e.value.toJson(),
        },
        'saFeedCache': {
          for (final e in trimmedSa) e.key: e.value.toJson(),
        },
        'calledBackKeys': _calledBackKeys.toList(),
        'resourceRoster': {
          for (final e in _resourcesById.entries)
            if (e.value.name.trim().isNotEmpty)
              e.key: {
                'name': e.value.name,
                if (e.value.territoryName != null)
                  'territory': e.value.territoryName,
              },
        },
      };
      await prefs.setString(_prefsCacheKey, jsonEncode(payload));
    } catch (_) {}
  }

  /// Injects or updates cached Chatter ETA (also used by unit tests).
  void cacheEtaForRecord(String recordId, ParsedChatterEta eta) {
    _etasByRecordId[recordId] = eta;
  }

  /// Injects or updates cached SA feed status times (also used by unit tests).
  void cacheSaFeedTimes(String saId, ParsedSaFeedTimes feedTimes) {
    _saFeedTimesBySaId[saId] = feedTimes;
  }

  /// Injects or updates cached Work Order Lightbox metadata (also used by unit tests).
  void cacheWorkOrderLightbox(String parentId, ParsedWorkOrderLightbox info) {
    _woCacheByParentId[parentId] = info;
  }

  /// Ingests raw appointments and resources directly (used by pollDelta and unit tests).
  void ingestAppointmentsAndResources({
    required List<FslServiceAppointmentDto> appointments,
    required List<FslResourceDto> resources,
    List<String> deletedAppointmentIds = const [],
    int? nowEpochMs,
  }) {
    final nowMs = nowEpochMs ?? DateTime.now().millisecondsSinceEpoch;

    for (final res in resources) {
      final existing = _resourcesById[res.id];
      final mergedName = res.name.trim().isNotEmpty
          ? res.name
          : (existing?.name ?? '');
      final mergedTerritory =
          res.territoryName ?? existing?.territoryName;
      _resourcesById[res.id] = FslResourceDto(
        id: res.id,
        name: mergedName,
        territoryName: mergedTerritory,
        latitude: res.latitude ?? existing?.latitude,
        longitude: res.longitude ?? existing?.longitude,
        lastLocationWallMs:
            res.lastLocationWallMs ?? existing?.lastLocationWallMs,
        isActive: res.isActive,
      );

      if (res.latitude != null && res.longitude != null) {
        final sampleEpoch = res.lastLocationWallMs != null
            ? FslTimeUtils.sfWallClockMsToEpochMs(res.lastLocationWallMs!)
            : nowMs;
        final history = _gpsHistoryByResource.putIfAbsent(res.id, () => []);
        if (history.isEmpty || history.last.epochMs != sampleEpoch) {
          history.add(_GpsSample(sampleEpoch, res.latitude!, res.longitude!));
        }
        // Keep last 3 hours of GPS samples
        history.removeWhere((s) => (nowMs - s.epochMs) > 3 * 3600 * 1000);
      }
    }

    for (final appt in appointments) {
      final prevStatus = _lastStatusBySa[appt.id];
      final isLiveFlip = prevStatus != null && prevStatus != appt.status;

      if (prevStatus != appt.status) {
        _lastStatusBySa[appt.id] = appt.status;
        _statusSinceEpochMsBySa[appt.id] = isLiveFlip
            ? nowMs
            : (appt.lastModifiedEpochMs ?? nowMs);
      }

      if (_arrivedStatuses.contains(appt.status) &&
          !_arrivedAtEpochMsBySa.containsKey(appt.id)) {
        _arrivedAtEpochMsBySa[appt.id] = isLiveFlip
            ? nowMs
            : (appt.actualStartWallMs != null
                  ? FslTimeUtils.sfWallClockMsToEpochMs(appt.actualStartWallMs!)
                  : (appt.lastModifiedEpochMs ?? nowMs));
        _arrivedLiveBySa[appt.id] = isLiveFlip;
      }

      // Fix tracker.py bug: record clearedAtEpochMs for BOTH completed AND cancelled calls!
      if (isTerminalStatus(appt.status) &&
          !_clearedAtEpochMsBySa.containsKey(appt.id)) {
        _clearedAtEpochMsBySa[appt.id] = isLiveFlip
            ? nowMs
            : (appt.lastModifiedEpochMs ?? nowMs);
      }

      // Ensure resource name/territory from the appointment is seeded into _resourcesById
      if (appt.resourceId != null &&
          appt.resourceId!.isNotEmpty &&
          appt.resourceName != null &&
          appt.resourceName!.isNotEmpty) {
        final rid = appt.resourceId!;
        final existing = _resourcesById[rid];
        if (existing == null || existing.name.trim().isEmpty) {
          _resourcesById[rid] = FslResourceDto(
            id: rid,
            name: appt.resourceName!,
            territoryName:
                appt.resourceContractorName ?? existing?.territoryName,
            latitude: existing?.latitude,
            longitude: existing?.longitude,
            lastLocationWallMs: existing?.lastLocationWallMs,
          );
        }
      }

      _appointmentsById[appt.id] = appt;
    }

    for (final deletedId in deletedAppointmentIds) {
      _appointmentsById.remove(deletedId);
    }
  }

  /// Ensures we have a fresh Visualforce Remoting context and territory list.
  /// Automatically refreshes the context if older than 40 minutes.
  Future<void> _ensureContext({bool forceRefresh = false}) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final isExpired =
        _remotingCtx == null ||
        (nowMs - _remotingCtx!.fetchedAtEpochMs) > 40 * 60 * 1000;

    if (forceRefresh || isExpired) {
      _remotingCtx = await _apiClient.fetchRemotingContext();
      if (_territoryLocations.isEmpty || forceRefresh) {
        _territoryLocations = await _apiClient.fetchUserTerritoryLocations(
          _remotingCtx!,
        );
      }
      try {
        final rosterResources = await _apiClient.fetchResourcesAndTerritories(
          ctx: _remotingCtx!,
          locations: _territoryLocations,
        );
        if (rosterResources.isNotEmpty) {
          ingestAppointmentsAndResources(
            appointments: const [],
            resources: rosterResources,
            nowEpochMs: nowMs,
          );
          unawaited(_saveDiskCache());
        }
      } catch (_) {}
    }
  }

  /// Polls `FSL.ctrl001_Gantt.getDelta`, runs a fast parallel Direct HTTP enrichment
  /// batch for missing Member Names / ETAs / Chatter timestamps, and returns the
  /// evaluated active [DispatchRow]s and [DispatchAlert]s.
  Future<({List<DispatchRow> rows, List<DispatchAlert> alerts})> pollDelta({
    bool fullShiftReload = false,
  }) async {
    await loadDiskCache();
    await _ensureContext(forceRefresh: fullShiftReload);
    final ctx = _remotingCtx!;
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // On initial load or full reload, look back 12 hours to capture the entire shift
    final sinceMs = (fullShiftReload || _lastUpdateTimeMs == null)
        ? nowMs - (12 * 3600 * 1000)
        : _lastUpdateTimeMs!;

    final dayBounds = FslTimeUtils.currentCentralDayBoundsWallClockMs();

    late final ({
      int serverUpdateTimeMs,
      List<FslServiceAppointmentDto> appointments,
      List<FslResourceDto> resources,
      List<String> deletedAppointmentIds,
    }) delta;

    try {
      delta = await _apiClient.fetchDelta(
        ctx: ctx,
        lastUpdateTimeMs: sinceMs,
        locations: _territoryLocations,
        minDateMs: dayBounds.minDateMs,
        maxDateMs: dayBounds.maxDateMs,
      );
    } catch (_) {
      // Token may have rotated; refresh context once and retry
      await _ensureContext(forceRefresh: true);
      delta = await _apiClient.fetchDelta(
        ctx: _remotingCtx!,
        lastUpdateTimeMs: sinceMs,
        locations: _territoryLocations,
        minDateMs: dayBounds.minDateMs,
        maxDateMs: dayBounds.maxDateMs,
      );
    }

    _lastUpdateTimeMs = delta.serverUpdateTimeMs;

    ingestAppointmentsAndResources(
      appointments: delta.appointments,
      resources: delta.resources,
      deletedAppointmentIds: delta.deletedAppointmentIds,
      nowEpochMs: nowMs,
    );

    // Run a fast bounded-concurrency Direct HTTP enrichment pass (up to 16 parallel GETs)
    // so backlog Member Names, wait/on-scene times, and active ETAs populate rapidly.
    final enrichedCount = await _enrichPendingRecordsParallel(
      nowMs: nowMs,
      maxParallelRequests: 16,
    );
    if (enrichedCount > 0) {
      unawaited(_saveDiskCache());
    }

    return evaluateCurrentState(nowEpochMs: nowMs);
  }

  /// Runs a single background enrichment batch (up to [maxParallelRequests] concurrent
  /// requests) for remaining un-enriched Callback Log or active records, rebuilds
  /// `_latestClearedCalls`, and returns `true` if any records were enriched.
  Future<bool> enrichNextBacklogBatch({int maxParallelRequests = 16}) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final count = await _enrichPendingRecordsParallel(
      nowMs: nowMs,
      maxParallelRequests: maxParallelRequests,
    );
    if (count > 0) {
      _latestClearedCalls = _buildClearedLog(nowMs);
      unawaited(_saveDiskCache());
      return true;
    }
    return false;
  }

  /// Fast parallel Direct HTTP enrichment worker pool (Rework #2).
  ///
  /// Prioritizes:
  /// 1. Active calls in `Dispatched`/`En Route` missing ETAs (`fsl__vf0996_workorderchatter`)
  ///    or exact SA status timestamps (`fsl__vf0993_servicechatter`).
  /// 2. Newest cleared/cancelled calls in the Callback Log, interleaving BOTH:
  ///    - `fsl__vf0999_workorderlightbox` (for Member Name & Benefit Level)
  ///    - `fsl__vf0993_servicechatter` (for exact Spotted/Dispatched/On Location/Cleared
  ///      timestamps across primary + mate legs so `Member waited` & `On scene` are accurate).
  Future<int> _enrichPendingRecordsParallel({
    required int nowMs,
    int maxParallelRequests = 16,
  }) async {
    final tasks = <Future<void> Function()>[];

    // 1. Active calls needing ETA (from WO chatter) or exact SA status times (from SA chatter)
    for (final appt in _appointmentsById.values) {
      if (tasks.length >= maxParallelRequests) break;
      if (appt.isDeleted || !_activeStatuses.contains(appt.status)) continue;
      if ((appt.callType ?? '').toUpperCase() == 'RAP') continue;

      final etaKey = appt.parentRecordId ?? appt.id;
      final existingEta =
          _etasByRecordId[appt.id] ?? _etasByRecordId[etaKey];
      final needsEta =
          (appt.status == 'Dispatched' || appt.status == 'En Route') &&
          (existingEta == null ||
              (nowMs - existingEta.postedEpochMs) > 45 * 60000) &&
          (nowMs - (_lastEtaFetchMs[etaKey] ?? 0)) > 2 * 60000;

      if (needsEta) {
        _lastEtaFetchMs[etaKey] = nowMs;
        tasks.add(() async {
          try {
            final page = appt.parentRecordId != null
                ? 'fsl__vf0996_workorderchatter'
                : 'fsl__vf0993_servicechatter';
            final html = await _apiClient.fetchVisualforcePage(page, etaKey);
            final eta = FslChatterParser.parseEtaFromFeed(
              html,
              nowEpochMs: nowMs,
            );
            if (eta != null) {
              _etasByRecordId[etaKey] = eta;
              _etasByRecordId[appt.id] = eta;
            }
            if (appt.parentRecordId != null) {
              final kmis = FslChatterParser.parseKmiMessages(html);
              if (kmis.isNotEmpty) {
                _kmiByParentId[appt.parentRecordId!] = kmis;
              }
            }
          } catch (_) {}
        });
      }

      if (tasks.length >= maxParallelRequests) break;
      final existingFeed = _saFeedTimesBySaId[appt.id];
      final lastFeedFetch = _lastSaFeedFetchMs[appt.id] ?? 0;
      final recordModifiedSinceFetch =
          (appt.lastModifiedEpochMs ?? 0) > lastFeedFetch;
      final needsSaFeed =
          (existingFeed == null || recordModifiedSinceFetch) &&
          (nowMs - lastFeedFetch) > 2 * 60000;

      if (needsSaFeed) {
        _lastSaFeedFetchMs[appt.id] = nowMs;
        tasks.add(() async {
          try {
            final html = await _apiClient.fetchVisualforcePage(
              'fsl__vf0993_servicechatter',
              appt.id,
            );
            final parsed = FslChatterParser.parseStatusTimesFromFeed(
              html,
              nowEpochMs: nowMs,
            );
            if (parsed.statusEpochs.isNotEmpty ||
                parsed.earliestStartEpochMs != null) {
              _saFeedTimesBySaId[appt.id] = parsed;
            }
          } catch (_) {}
        });
      }
    }

    // 2. Prioritize newest Cleared/Cancelled calls (within last 12 hours),
    //    interleaving WO Lightbox (Member Name) and SA Chatter Feed (Wait & On-Scene times)
    final clearedCandidates = _appointmentsById.values
        .where((a) {
          if (a.isDeleted) return false;
          if (!isTerminalStatus(a.status)) return false;
          if ((a.callType ?? '').toUpperCase() == 'RAP') return false;
          final clearedAt =
              _clearedAtEpochMsBySa[a.id] ?? a.lastModifiedEpochMs ?? nowMs;
          return (nowMs - clearedAt) <= 12 * 3600 * 1000;
        })
        .toList()
      ..sort(
        (a, b) => (_clearedAtEpochMsBySa[b.id] ?? b.lastModifiedEpochMs ?? 0)
            .compareTo(
              _clearedAtEpochMsBySa[a.id] ?? a.lastModifiedEpochMs ?? 0,
            ),
      );

    final queuedParentIds = <String>{};
    final queuedSaIds = <String>{};

    for (final appt in clearedCandidates) {
      if (tasks.length >= maxParallelRequests) break;

      // Queue WO Lightbox if missing Member Name / Benefit Level
      final pid = appt.parentRecordId;
      if (pid != null &&
          pid.isNotEmpty &&
          !_woCacheByParentId.containsKey(pid) &&
          (nowMs - (_lastWoFetchMs[pid] ?? 0)) > 2 * 60000 &&
          queuedParentIds.add(pid)) {
        _lastWoFetchMs[pid] = nowMs;
        tasks.add(() async {
          try {
            final html = await _apiClient.fetchVisualforcePage(
              'fsl__vf0999_workorderlightbox',
              pid,
            );
            final info = FslChatterParser.parseWorkOrderLightbox(html);
            if (info.memberName != null || info.benefitLevel != null) {
              _woCacheByParentId[pid] = info;
            }
          } catch (_) {}
        });
      }

      if (tasks.length >= maxParallelRequests) break;

      // Queue SA Chatter Feed for primary leg and mate leg if missing or pre-terminal
      // (Never skip based on ActualStartTime because Salesforce sets ActualStartTime == SchedStartTime)
      final mate = _findMateAppointment(appt);
      final legIds = <String>[
        appt.id,
        if (mate != null) mate.id,
      ];

      for (final saId in legIds) {
        if (tasks.length >= maxParallelRequests) break;
        if (!queuedSaIds.add(saId)) continue;
        final existingFeed = _saFeedTimesBySaId[saId];
        final needsClearedFeed =
            existingFeed == null || !existingFeed.hasTerminalStatus;
        if (!needsClearedFeed) continue;
        if ((nowMs - (_lastSaFeedFetchMs[saId] ?? 0)) <= 2 * 60000) continue;

        _lastSaFeedFetchMs[saId] = nowMs;
        tasks.add(() async {
          try {
            final html = await _apiClient.fetchVisualforcePage(
              'fsl__vf0993_servicechatter',
              saId,
            );
            final parsed = FslChatterParser.parseStatusTimesFromFeed(
              html,
              nowEpochMs: nowMs,
            );
            if (parsed.statusEpochs.isNotEmpty ||
                parsed.earliestStartEpochMs != null) {
              _saFeedTimesBySaId[saId] = parsed;
            }
          } catch (_) {}
        });
      }
    }

    if (tasks.isNotEmpty) {
      await Future.wait(tasks.map((fn) => fn()));
    }
    return tasks.length;
  }

  /// Evaluates current in-memory appointments and resources into active
  /// [DispatchRow]s, [DispatchAlert]s, and the 12-hour [clearedCalls] Callback Log.
  ({List<DispatchRow> rows, List<DispatchAlert> alerts}) evaluateCurrentState({
    int? nowEpochMs,
  }) {
    final nowMs = nowEpochMs ?? DateTime.now().millisecondsSinceEpoch;
    final byResource = <String, List<FslServiceAppointmentDto>>{};
    final driversOnRap = <String>{};

    for (final appt in _appointmentsById.values) {
      if (appt.isDeleted) continue;
      final rid = appt.resourceId;
      if (rid == null || rid.isEmpty) continue;

      final isRap =
          (appt.callType ?? '').toUpperCase() == 'RAP' ||
          appt.status.toLowerCase().contains('rap');
      if (isRap) {
        if (!isTerminalStatus(appt.status) && !_isFutureDay(appt, nowMs)) {
          driversOnRap.add(rid);
        }
        continue;
      }

      if (isTerminalStatus(appt.status)) continue;
      if (!_activeStatuses.contains(appt.status)) continue;
      if (_isFutureDay(appt, nowMs)) continue;

      if (appt.schedStartWallMs != null) {
        final schedEpoch = FslTimeUtils.sfWallClockMsToEpochMs(
          appt.schedStartWallMs!,
        );
        // Filter out stale Scheduled ghost calls (> 3h past scheduled start)
        if (appt.status == 'Scheduled' &&
            (nowMs - schedEpoch) > 3 * 3600 * 1000) {
          continue;
        }
        // Filter out abandoned old calls (> 6h past scheduled start with no update in > 3h)
        final lastModEpoch = appt.lastModifiedEpochMs ?? schedEpoch;
        if ((nowMs - schedEpoch) > 6 * 3600 * 1000 &&
            (nowMs - lastModEpoch) > 3 * 3600 * 1000) {
          continue;
        }
      }

      byResource.putIfAbsent(rid, () => []).add(appt);
    }

    final rows = <DispatchRow>[];
    final allAlerts = <DispatchAlert>[];

    for (final entry in byResource.entries) {
      final resourceId = entry.key;
      final candidates = entry.value;
      if (candidates.isEmpty) continue;

      final selected = _selectPrimaryAppointmentForDriver(candidates);
      final primary = selected.primary;
      if (primary == null) continue;
      final isChainSecond = selected.isChainSecondLeg;

      final resource = _resourcesById[resourceId];
      String? fallbackResourceName = primary.resourceName;
      if (fallbackResourceName == null || fallbackResourceName.trim().isEmpty) {
        for (final other in _appointmentsById.values) {
          if (other.resourceId == resourceId &&
              other.resourceName != null &&
              other.resourceName!.trim().isNotEmpty) {
            fallbackResourceName = other.resourceName;
            break;
          }
        }
      }
      final rawDriverName =
          (resource != null && resource.name.trim().isNotEmpty)
          ? resource.name
          : (fallbackResourceName ?? resourceId);
      final cleanDriverName = FslTimeUtils.cleanDriverName(rawDriverName);
      final phones = FslTimeUtils.extractPhones(rawDriverName);

      final feedTimes = _saFeedTimesBySaId[primary.id];
      final feedStatusEpoch = feedTimes?.statusEpochs[primary.status];
      final observedStatusEpoch = _statusSinceEpochMsBySa[primary.id];
      final statusSinceMs = (feedStatusEpoch != null &&
              (observedStatusEpoch == null ||
                  feedStatusEpoch > observedStatusEpoch))
          ? feedStatusEpoch
          : (observedStatusEpoch ?? primary.lastModifiedEpochMs ?? nowMs);

      final statusDurationMin =
          ((nowMs - statusSinceMs) / 60000.0).clamp(0.0, 999.0);

      double? distKm;
      if (resource?.latitude != null &&
          resource?.longitude != null &&
          primary.latitude != null &&
          primary.longitude != null) {
        final meters = FslTimeUtils.haversineMeters(
          resource!.latitude!,
          resource.longitude!,
          primary.latitude!,
          primary.longitude!,
        );
        distKm = double.parse((meters / 1000.0).toStringAsFixed(1));
      }

      double? gpsAgeMin;
      if (resource?.lastLocationWallMs != null) {
        final locEpoch = FslTimeUtils.sfWallClockMsToEpochMs(
          resource!.lastLocationWallMs!,
        );
        gpsAgeMin = double.parse(
          (((nowMs - locEpoch) / 60000.0).clamp(0.0, 999.0)).toStringAsFixed(1),
        );
      }

      final movement = _evaluateDriverMovement(
        resourceId: resourceId,
        appointment: primary,
        mateAppointment: selected.mate,
        distanceToPickupKm: distKm,
        statusSinceEpochMs: statusSinceMs,
        nowMs: nowMs,
      );

      final isRedAlert = FslTimeUtils.isRedAlertColor(primary.ganttColorHex);
      final busyOnRap = driversOnRap.contains(resourceId);
      final effectiveStatus =
          (busyOnRap &&
              (primary.status == 'Scheduled' || primary.status == 'Dispatched'))
          ? 'On RAP'
          : primary.status;

      // Evaluate ETA & Rework #1 (Reassigned hiding + Placeholder/Unrealistic Stale flagging)
      final rawEta =
          _etasByRecordId[primary.id] ??
          (primary.parentRecordId != null
              ? _etasByRecordId[primary.parentRecordId!]
              : null);

      String? etaText;
      String? etaWindowText;
      int? etaLowMin;
      int? etaHighMin;
      int? etaPostedEpochMs;
      var etaIsStale = false;
      String? etaStaleReason;
      var etaIsExpired = false;
      var etaExpiredMin = 0.0;

      if (rawEta != null) {
        final latestDispatchedMs =
            feedTimes?.latestDispatchedEpochMs ??
            (primary.status == 'Dispatched' ? statusSinceMs : null);
        final eval = FslChatterParser.evaluateEtaValidity(
          eta: rawEta,
          currentStatus: effectiveStatus,
          nowEpochMs: nowMs,
          latestDispatchedEpochMs: latestDispatchedMs,
          wasReassigned: feedTimes?.wasReassigned ?? false,
          distanceToCallKm: distKm,
          movementState: movement.state,
          isDriverBusyOnRap: busyOnRap,
        );

        if (!eval.hideCompletely) {
          etaText = rawEta.rawText;
          etaWindowText = rawEta.formatWindowCentral();
          etaLowMin = rawEta.lowMin;
          etaHighMin = rawEta.highMin;
          etaPostedEpochMs = rawEta.postedEpochMs;
          etaIsStale = eval.isStale;
          etaStaleReason = eval.staleReason;
          etaIsExpired = eval.isExpired;
          etaExpiredMin = eval.expiredMinutes;
        }
      }

      // Evaluate consolidated 3 built-in alerts
      final rowAlerts = <DispatchAlert>[];

      // 1. DISPATCH_OVERDUE (> 10m in Dispatched, unless chain_second or busy_on_rap)
      if (primary.status == 'Dispatched' &&
          statusDurationMin >= 10.0 &&
          !isChainSecond &&
          !busyOnRap) {
        rowAlerts.add(
          DispatchAlert(
            type: DispatchAlertType.dispatchOverdue,
            driverName: rawDriverName,
            driverId: resourceId,
            callId: primary.callId ?? primary.appointmentNumber,
            appointmentNumber: primary.appointmentNumber,
            status: primary.status,
            workType: primary.workTypeName ?? '',
            detail:
                'Dispatched ${statusDurationMin.round()} min without En Route',
            sinceEpochMs: statusSinceMs,
            durationMin: statusDurationMin,
            distanceKm: distKm,
          ),
        );
      }

      // 2. STANDING_STILL (Consolidated standstill + distance alert while En Route)
      if (primary.status == 'En Route' &&
          movement.state == 'STANDSTILL' &&
          (movement.durationMin ?? 0) >= 10) {
        final distSuffix = distKm != null
            ? ' (${distKm.toStringAsFixed(1)} km from call)'
            : '';
        rowAlerts.add(
          DispatchAlert(
            type: DispatchAlertType.standingStill,
            driverName: rawDriverName,
            driverId: resourceId,
            callId: primary.callId ?? primary.appointmentNumber,
            appointmentNumber: primary.appointmentNumber,
            status: primary.status,
            workType: primary.workTypeName ?? '',
            detail:
                'Standing still ${movement.durationMin} min while En Route$distSuffix',
            sinceEpochMs: nowMs - ((movement.durationMin ?? 10) * 60000),
            durationMin: (movement.durationMin ?? 10).toDouble(),
            distanceKm: distKm,
          ),
        );
      }

      // 3. ETA_EXPIRED (Fires when a valid, non-stale ETA's upper bound has passed)
      if (etaIsExpired && rawEta != null) {
        rowAlerts.add(
          DispatchAlert(
            type: DispatchAlertType.etaExpired,
            driverName: rawDriverName,
            driverId: resourceId,
            callId: primary.callId ?? primary.appointmentNumber,
            appointmentNumber: primary.appointmentNumber,
            status: primary.status,
            workType: primary.workTypeName ?? '',
            detail:
                'ETA $etaWindowText expired ${etaExpiredMin.round()} min ago',
            sinceEpochMs: rawEta.highTargetEpochMs,
            durationMin: etaExpiredMin,
            distanceKm: distKm,
          ),
        );
      }

      allAlerts.addAll(rowAlerts);

      final addressParts = [
        if (primary.street != null && primary.street!.isNotEmpty)
          primary.street!,
        if (primary.city != null &&
            primary.city!.isNotEmpty &&
            !(primary.street ?? '').contains(primary.city!))
          primary.city!,
      ];

      final dropoffAddr = _resolveDropoffAddress(primary, selected.mate);
      final kmiList = primary.parentRecordId != null
          ? (_kmiByParentId[primary.parentRecordId!] ?? const [])
          : const <String>[];

      rows.add(
        DispatchRow(
          resourceId: resourceId,
          driverRawName: rawDriverName,
          driverCleanName: cleanDriverName,
          driverPhones: phones,
          serviceAppointmentId: primary.id,
          appointmentNumber: primary.appointmentNumber,
          callId: primary.callId ?? primary.appointmentNumber,
          territoryGroup:
              primary.resourceContractorName ??
              resource?.territoryName ??
              '',
          workType: primary.workTypeName ?? '',
          status: effectiveStatus,
          statusDurationMin: double.parse(statusDurationMin.toStringAsFixed(1)),
          isChainSecondLeg: isChainSecond,
          isRedAlert: isRedAlert,
          alerts: rowAlerts,
          ganttColorHex: primary.ganttColorHex,
          memberVehicle: primary.memberVehicle ?? primary.ganttLabel,
          pickupAddress: addressParts.isEmpty ? null : addressParts.join(', '),
          dropoffAddress: dropoffAddr,
          distanceToCallKm: distKm,
          gpsAgeMin: gpsAgeMin,
          driverLat: resource?.latitude,
          driverLon: resource?.longitude,
          callLat: primary.latitude,
          callLon: primary.longitude,
          movementState: movement.state,
          movementDurationMin: movement.durationMin,
          etaText: etaText,
          etaWindowText: etaWindowText,
          etaLowMin: etaLowMin,
          etaHighMin: etaHighMin,
          etaPostedEpochMs: etaPostedEpochMs,
          etaIsStale: etaIsStale,
          etaStaleReason: etaStaleReason,
          kmiComments: kmiList,
        ),
      );
    }

    rows.sort((a, b) {
      if (a.alerts.isNotEmpty != b.alerts.isNotEmpty) {
        return a.alerts.isNotEmpty ? -1 : 1;
      }
      if (a.isRedAlert != b.isRedAlert) {
        return a.isRedAlert ? -1 : 1;
      }
      return a.driverCleanName.compareTo(b.driverCleanName);
    });

    // Rebuild the 12-hour Callback Log (`_latestClearedCalls`)
    _latestClearedCalls = _buildClearedLog(nowMs);

    return (rows: rows, alerts: allAlerts);
  }

  /// Builds the 12-hour Callback Log (`Cleared Calls`), including:
  /// - Instant Wait & On-Scene calculation using `ActualStartTime` + `SchedStartTime`
  ///   from `getDelta` (merged with any SA Chatter feed timestamps across 2-leg tow pairs).
  /// - Full support for `Canceled` / `Cannot Complete` calls (`isCancelled: true`).
  /// - Territory (`territory`) and Red Alert (`isRedAlert`) indicators.
  List<ClearedCall> _buildClearedLog(int nowMs) {
    final doneAppts = _appointmentsById.values.where((s) {
      if (s.isDeleted) return false;
      if ((s.callType ?? '').toUpperCase() == 'RAP') return false;
      if (!isTerminalStatus(s.status)) return false;
      final clearedAt =
          _clearedAtEpochMsBySa[s.id] ?? s.lastModifiedEpochMs ?? nowMs;
      return (nowMs - clearedAt) <= 12 * 3600 * 1000;
    }).toList();

    doneAppts.sort((a, b) {
      final sa = a.schedStartWallMs ?? 0;
      final sb = b.schedStartWallMs ?? 0;
      if (sa != sb) return sa.compareTo(sb);
      return a.appointmentNumber.compareTo(b.appointmentNumber);
    });

    final doneIds = doneAppts.map((a) => a.id).toSet();
    final seenIds = <String>{};
    final byCallAndDriver = <String, ClearedCall>{};

    for (final s in doneAppts) {
      final relId = s.relatedService1Id ?? s.parentTowSaId;
      final isFollow =
          (s.dependencyType ?? '').toLowerCase().contains('follow') ||
          s.parentTowSaId != null;

      if (relId != null && doneIds.contains(relId) && isFollow) {
        final mate = _appointmentsById[relId];
        if (mate != null) {
          final mateSched = mate.schedStartWallMs ?? 0;
          final mySched = s.schedStartWallMs ?? 0;
          if (mySched > mateSched ||
              (mySched == mateSched &&
                  s.appointmentNumber.compareTo(mate.appointmentNumber) > 0)) {
            // Second leg of a completed pair; head leg represents the pair
            continue;
          }
        }
      }

      if (!seenIds.add(s.id)) continue;

      final mate = _findMateAppointment(s);
      final legIds = <String>{
        s.id,
        if (mate != null) mate.id,
        if (s.callId != null && s.resourceId != null)
          ...doneAppts
              .where(
                (other) =>
                    other.callId == s.callId &&
                    other.resourceId == s.resourceId,
              )
              .map((other) => other.id),
      };

      // Merge SA feed timestamps across all legs of the call for this driver
      final mergedFeedEpochs = <String, int>{};
      int? earliestFeedStartMs;
      var wasReassigned = false;
      for (final lid in legIds) {
        final ft = _saFeedTimesBySaId[lid];
        if (ft != null) {
          if (ft.wasReassigned) wasReassigned = true;
          final legStart = ft.earliestStartEpochMs;
          if (legStart != null &&
              (earliestFeedStartMs == null || legStart < earliestFeedStartMs)) {
            earliestFeedStartMs = legStart;
          }
          for (final entry in ft.statusEpochs.entries) {
            final cur = mergedFeedEpochs[entry.key];
            if (cur == null || entry.value < cur) {
              mergedFeedEpochs[entry.key] = entry.value;
            }
          }
        }
      }

      final schedEpochFromDelta = s.schedStartWallMs != null
          ? FslTimeUtils.sfWallClockMsToEpochMs(s.schedStartWallMs!)
          : (mate?.schedStartWallMs != null
                ? FslTimeUtils.sfWallClockMsToEpochMs(mate!.schedStartWallMs!)
                : null);

      final actualStartEpochFromDelta = s.actualStartWallMs != null
          ? FslTimeUtils.sfWallClockMsToEpochMs(s.actualStartWallMs!)
          : (mate?.actualStartWallMs != null
                ? FslTimeUtils.sfWallClockMsToEpochMs(mate!.actualStartWallMs!)
                : null);

      final feedStartCandidates = <int>[
        ?earliestFeedStartMs,
        ?mergedFeedEpochs['Spotted'],
        ?mergedFeedEpochs['Scheduled'],
        ?mergedFeedEpochs['Dispatched'],
      ];

      final earliestStartMs = feedStartCandidates.isNotEmpty
          ? feedStartCandidates.reduce((a, b) => a < b ? a : b)
          : schedEpochFromDelta;

      final clearedMs =
          mergedFeedEpochs['Cleared'] ??
          mergedFeedEpochs['Tow Complete'] ??
          mergedFeedEpochs['Complete'] ??
          mergedFeedEpochs['Canceled'] ??
          mergedFeedEpochs['Cannot Complete'] ??
          _clearedAtEpochMsBySa[s.id] ??
          s.lastModifiedEpochMs ??
          nowMs;

      final liveArrivedMs = (_arrivedLiveBySa[s.id] == true)
          ? _arrivedAtEpochMsBySa[s.id]
          : (mate != null && _arrivedLiveBySa[mate.id] == true
                ? _arrivedAtEpochMsBySa[mate.id]
                : null);

      // Salesforce getDelta sets ActualStartTime == SchedStartTime on almost all calls.
      // Only trust ActualStartTime from getDelta if SA feed hasn't been fetched yet
      // AND ActualStartTime is genuinely distinct (> 2 min after SchedStartTime).
      final validDeltaActualStartMs = (mergedFeedEpochs.isEmpty &&
              actualStartEpochFromDelta != null &&
              schedEpochFromDelta != null &&
              (actualStartEpochFromDelta - schedEpochFromDelta) > 2 * 60000 &&
              actualStartEpochFromDelta <= clearedMs)
          ? actualStartEpochFromDelta
          : null;

      final arrivedMs =
          mergedFeedEpochs['On Location'] ??
          mergedFeedEpochs['Tow Loaded'] ??
          liveArrivedMs ??
          validDeltaActualStartMs;

      final isCancelled =
          isCancelledStatus(s.status) ||
          (mate != null &&
              isCancelledStatus(mate.status) &&
              !_completedStatuses.contains(s.status));

      int? waitMin;
      if (arrivedMs != null && earliestStartMs != null) {
        final diffMin = ((arrivedMs - earliestStartMs) / 60000.0).round();
        if (diffMin >= 0 && diffMin <= 720) {
          waitMin = diffMin;
        }
      }

      int? onSceneMin;
      if (!isCancelled && arrivedMs != null && clearedMs >= arrivedMs) {
        final diffMin = ((clearedMs - arrivedMs) / 60000.0).round();
        if (diffMin >= 0 && diffMin <= 720) {
          onSceneMin = diffMin;
        }
      }

      final woInfo = s.parentRecordId != null
          ? _woCacheByParentId[s.parentRecordId!]
          : null;

      final resource = s.resourceId != null
          ? _resourcesById[s.resourceId!]
          : null;
      final rawDriver =
          s.resourceName ?? resource?.name ?? s.resourceId ?? 'Unassigned';
      final cleanDriver = FslTimeUtils.cleanDriverName(rawDriver);

      final territory =
          (s.resourceContractorName ??
                  resource?.territoryName ??
                  mate?.resourceContractorName ??
                  '')
              .trim();
      final ganttColor = s.ganttColorHex ?? mate?.ganttColorHex;
      final isRedAlert = FslTimeUtils.isRedAlertColor(ganttColor);

      final callId = s.callId ?? s.appointmentNumber;
      final uniqueKey = '${callId}_$cleanDriver';
      final calledBack =
          _calledBackKeys.contains(uniqueKey) ||
          _calledBackKeys.contains(callId);

      final candidate = ClearedCall(
        serviceAppointmentId: s.id,
        appointmentNumber: s.appointmentNumber,
        callId: callId,
        status: isCancelled ? 'Canceled' : s.status,
        driverName: cleanDriver,
        clearedAtEpochMs: clearedMs,
        territory: territory,
        isRedAlert: isRedAlert,
        isCancelled: isCancelled,
        ganttColorHex: ganttColor,
        schedStartEpochMs: earliestStartMs,
        workOrderId: s.parentRecordId,
        workType: s.workTypeName ?? woInfo?.workType ?? s.callType,
        memberName: woInfo?.memberName ?? s.memberName ?? mate?.memberName,
        memberPhone: s.memberPhone ?? mate?.memberPhone,
        benefitLevel:
            woInfo?.benefitLevel ?? s.benefitLevel ?? mate?.benefitLevel,
        memberVehicle:
            s.memberVehicle ?? s.ganttLabel ?? mate?.memberVehicle,
        waitDurationMin: waitMin,
        onSceneDurationMin: onSceneMin,
        wasReassigned: wasReassigned,
        calledBack: calledBack,
      );

      final existing = byCallAndDriver[uniqueKey];
      if (existing == null ||
          candidate.clearedAtEpochMs >= existing.clearedAtEpochMs) {
        byCallAndDriver[uniqueKey] = candidate;
      }
    }

    final list = byCallAndDriver.values.toList()
      ..sort((a, b) => b.clearedAtEpochMs.compareTo(a.clearedAtEpochMs));
    return list;
  }

  bool _isFutureDay(FslServiceAppointmentDto appt, int nowMs) {
    if (appt.schedStartWallMs == null) return false;
    final schedEpoch = FslTimeUtils.sfWallClockMsToEpochMs(
      appt.schedStartWallMs!,
    );
    return !FslTimeUtils.isSameOrEarlierCentralDay(
      schedEpoch,
      nowEpochMs: nowMs,
    );
  }

  FslServiceAppointmentDto? _findMateAppointment(
    FslServiceAppointmentDto svc,
  ) {
    final rel = svc.relatedService1Id ?? svc.parentTowSaId;
    if (rel != null && _appointmentsById.containsKey(rel)) {
      return _appointmentsById[rel];
    }
    for (final s in _appointmentsById.values) {
      if (s.id != svc.id &&
          (s.relatedService1Id == svc.id || s.parentTowSaId == svc.id)) {
        return s;
      }
    }
    if (svc.resourceId != null && svc.callId != null) {
      final matches = _appointmentsById.values
          .where(
            (s) =>
                s.id != svc.id &&
                s.resourceId == svc.resourceId &&
                s.callId == svc.callId,
          )
          .toList();
      if (matches.length == 1) return matches.first;
    }
    return null;
  }

  String? _resolveDropoffAddress(
    FslServiceAppointmentDto primary,
    FslServiceAppointmentDto? mate,
  ) {
    final partner = mate ?? _findMateAppointment(primary);
    if (partner == null) return null;
    final mySched = primary.schedStartWallMs ?? 0;
    final partnerSched = partner.schedStartWallMs ?? 0;
    if (mySched > partnerSched) {
      return null; // Primary leg is already the destination leg
    }
    final parts = [
      if (partner.street != null && partner.street!.isNotEmpty) partner.street!,
      if (partner.city != null &&
          partner.city!.isNotEmpty &&
          !(partner.street ?? '').contains(partner.city!))
        partner.city!,
    ];
    if (parts.isNotEmpty) return parts.join(', ');
    return _dropoffCacheBySaId[partner.id];
  }

  /// Selects the current active appointment for a driver, matching the original
  /// `tracker.py` `first_service()` logic:
  /// - Pairs up `Immediately Follow` tow legs: if both are active, excludes the
  ///   second leg unless the head is still `Dispatched` while the second has
  ///   progressed (`En Route`/`On Location`/`Tow Loaded`/`In Tow`).
  /// - When a driver has multiple calls and one is actively being worked
  ///   (`En Route`/`On Location`/`Tow Loaded`/`In Tow`/`Dispatched`) while an
  ///   older unstarted `Scheduled` call is lingering behind it, prefers the
  ///   active call over the lingering `Scheduled` call.
  /// - If the selected call's `Immediately Follow` mate is already in `In Tow`
  ///   or `Tow Complete` (e.g. first leg left behind at `Tow Loaded` when the
  ///   tow completed), returns `null` so the finished call is dropped.
  ({
    FslServiceAppointmentDto? primary,
    FslServiceAppointmentDto? mate,
    bool isChainSecondLeg,
  })
  _selectPrimaryAppointmentForDriver(
    List<FslServiceAppointmentDto> candidates,
  ) {
    int parseApptNum(FslServiceAppointmentDto s) {
      final digits = s.appointmentNumber.replaceAll(RegExp(r'[^0-9]'), '');
      return int.tryParse(digits) ?? 0;
    }

    int compareSchedAndAppt(
      FslServiceAppointmentDto a,
      FslServiceAppointmentDto b,
    ) {
      final sa = a.schedStartWallMs ?? 0;
      final sb = b.schedStartWallMs ?? 0;
      if (sa != sb) return sa.compareTo(sb);
      final na = parseApptNum(a);
      final nb = parseApptNum(b);
      if (na != nb) return na.compareTo(nb);
      return a.appointmentNumber.compareTo(b.appointmentNumber);
    }

    const progressedStatuses = {
      'En Route',
      'On Location',
      'Tow Loaded',
      'In Tow',
    };

    final byId = <String, FslServiceAppointmentDto>{
      for (final c in candidates) c.id: c,
    };
    final excludedIds = <String>{};
    final chainSecondIds = <String>{};
    final processedIds = <String>{};

    for (final s in candidates) {
      if (processedIds.contains(s.id)) continue;
      final relId = s.relatedService1Id ?? s.parentTowSaId;
      final isFollow =
          (s.dependencyType ?? '').toLowerCase().contains('follow') ||
          s.parentTowSaId != null;
      if (relId == null ||
          !isFollow ||
          !byId.containsKey(relId) ||
          processedIds.contains(relId)) {
        continue;
      }
      final mate = byId[relId]!;
      processedIds.add(s.id);
      processedIds.add(mate.id);

      final isMateHead = compareSchedAndAppt(mate, s) <= 0;
      final head = isMateHead ? mate : s;
      final second = isMateHead ? s : mate;

      if (head.status == 'Dispatched' &&
          progressedStatuses.contains(second.status)) {
        // Second leg is the live one
        excludedIds.add(head.id);
        chainSecondIds.add(second.id);
      } else {
        excludedIds.add(second.id);
      }
    }

    var remaining = candidates
        .where((c) => !excludedIds.contains(c.id))
        .toList();
    if (remaining.isEmpty) {
      return (primary: null, mate: null, isChainSecondLeg: false);
    }

    // If any candidate is actively dispatched/being worked, drop unstarted 'Scheduled'
    // candidates so a lingering past-due Scheduled call never hides a driver's live call
    // or vice-versa.
    final hasWorkingCall = remaining.any((c) => c.status != 'Scheduled');
    if (hasWorkingCall) {
      remaining = remaining.where((c) => c.status != 'Scheduled').toList();
    }

    // Sort remaining active calls: progressed/dispatched status rank first, then earliest schedStart
    remaining.sort((a, b) {
      final rankA = _statusPriorityRank(a.status);
      final rankB = _statusPriorityRank(b.status);
      if (rankA != rankB) return rankA.compareTo(rankB);
      return compareSchedAndAppt(a, b);
    });

    final primary = remaining.first;
    final mate = _findMateAppointment(primary);

    // If this leg is stuck at 'Tow Loaded' or 'On Location' while its destination tow leg
    // is already 'Tow Complete' or 'Cleared', the tow is finished!
    if (mate != null && isTerminalStatus(mate.status)) {
      final isPrimaryEarlierLeg = compareSchedAndAppt(primary, mate) <= 0;
      if (isPrimaryEarlierLeg &&
          (primary.status == 'Tow Loaded' ||
              primary.status == 'On Location' ||
              primary.status == 'In Tow')) {
        return (primary: null, mate: mate, isChainSecondLeg: false);
      }
    }

    final isSecond =
        chainSecondIds.contains(primary.id) ||
        (mate != null &&
            isTerminalStatus(mate.status) &&
            compareSchedAndAppt(mate, primary) <= 0);

    return (
      primary: primary,
      mate: mate,
      isChainSecondLeg: isSecond,
    );
  }

  int _statusPriorityRank(String status) {
    switch (status) {
      case 'In Tow':
      case 'Tow Loaded':
      case 'On Location':
        return 1;
      case 'En Route':
        return 2;
      case 'Dispatched':
        return 3;
      default:
        return 4;
    }
  }

  ({String? state, int? durationMin}) _evaluateDriverMovement({
    required String resourceId,
    required FslServiceAppointmentDto appointment,
    required FslServiceAppointmentDto? mateAppointment,
    required double? distanceToPickupKm,
    required int statusSinceEpochMs,
    required int nowMs,
  }) {
    if (distanceToPickupKm != null && distanceToPickupKm <= 0.30) {
      return (state: 'AT LOC', durationMin: null);
    }

    final samples = _gpsHistoryByResource[resourceId];
    if (samples == null || samples.length < 2) {
      return (state: null, durationMin: null);
    }

    final latest = samples.last;
    if (mateAppointment?.latitude != null &&
        mateAppointment?.longitude != null) {
      final distToMateM = FslTimeUtils.haversineMeters(
        latest.lat,
        latest.lon,
        mateAppointment!.latitude!,
        mateAppointment.longitude!,
      );
      if (distToMateM <= 300.0) {
        return (state: 'AT DROP OFF', durationMin: null);
      }
    }

    // Measure how long the driver has stayed within a 150m radius of latest position
    // since entering the current status (standstill timer resets on status change).
    int standstillStartMs = latest.epochMs;
    for (int i = samples.length - 2; i >= 0; i--) {
      final s = samples[i];
      final movedM = FslTimeUtils.haversineMeters(
        latest.lat,
        latest.lon,
        s.lat,
        s.lon,
      );
      if (movedM < 150.0) {
        if (s.epochMs <= statusSinceEpochMs) {
          standstillStartMs = statusSinceEpochMs;
          break;
        }
        standstillStartMs = s.epochMs;
      } else {
        break;
      }
    }

    if (standstillStartMs < statusSinceEpochMs) {
      standstillStartMs = statusSinceEpochMs;
    }

    final standstillMin = ((nowMs - standstillStartMs) / 60000.0).floor();
    if (standstillMin >= 10) {
      return (state: 'STANDSTILL', durationMin: standstillMin);
    }
    return (state: 'MOVING', durationMin: null);
  }

  /// Toggles the "Called Back" checkbox for a Callback Log entry by its `uniqueKey` or `callId`.
  void toggleCalledBack(String keyOrCallId) {
    if (_calledBackKeys.contains(keyOrCallId)) {
      _calledBackKeys.remove(keyOrCallId);
    } else {
      _calledBackKeys.add(keyOrCallId);
    }
    _latestClearedCalls = _latestClearedCalls.map((c) {
      if (c.uniqueKey == keyOrCallId || c.callId == keyOrCallId) {
        return c.copyWith(calledBack: !c.calledBack);
      }
      return c;
    }).toList();
    unawaited(_saveDiskCache());
  }
}
