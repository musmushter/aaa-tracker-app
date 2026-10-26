import 'fsl_time_utils.dart';

/// Parsed ETA commitment from a Salesforce Work Order or Service Appointment Chatter feed.
class ParsedChatterEta {
  const ParsedChatterEta({
    required this.rawText,
    required this.lowMin,
    required this.highMin,
    required this.postedEpochMs,
    required this.lowTargetEpochMs,
    required this.highTargetEpochMs,
  });

  final String rawText;
  final int lowMin;
  final int highMin;
  final int postedEpochMs;
  final int lowTargetEpochMs;
  final int highTargetEpochMs;

  /// Formats the ETA target window in `America/Chicago` Central Time
  /// (e.g. `2:15 PM` or `2:15 PM–2:30 PM`).
  String formatWindowCentral() {
    final loStr = FslTimeUtils.formatCentralTime(lowTargetEpochMs);
    final hiStr = FslTimeUtils.formatCentralTime(highTargetEpochMs);
    if ((highTargetEpochMs - lowTargetEpochMs).abs() < 60000) {
      return hiStr;
    }
    return '$loStr–$hiStr';
  }
}

/// Result of evaluating whether a parsed ETA should be shown, hidden (reassigned),
/// or flagged as stale/unrealistic/placeholder.
class EtaValidityResult {
  const EtaValidityResult({
    required this.hideCompletely,
    required this.isStale,
    this.staleReason,
    this.isExpired = false,
    this.expiredMinutes = 0.0,
  });

  /// True when the ETA belonged to a previous driver before reassignment,
  /// or expired >45 minutes ago and is just historical noise.
  final bool hideCompletely;

  /// True when the ETA is a same-driver placeholder or physically unrealistic.
  final bool isStale;

  /// Short human-readable badge reason (e.g., `'PRE-DISPATCH'`, `'UNREALISTIC'`, `'PLACEHOLDER'`).
  final String? staleReason;

  /// True when a valid (non-stale, non-hidden) ETA's upper window has passed.
  final bool isExpired;

  /// Minutes past `highTargetEpochMs` when `isExpired` is true.
  final double expiredMinutes;
}

/// Parsed lifecycle timestamps and reassignment count from `fsl__vf0993_servicechatter`.
class ParsedSaFeedTimes {
  const ParsedSaFeedTimes({
    required this.statusEpochs,
    required this.dispatchOrEnRoutePostCount,
    this.earliestStartEpochMs,
    this.earliestDispatchedEpochMs,
    this.latestDispatchedEpochMs,
  });

  factory ParsedSaFeedTimes.fromJson(Map<String, dynamic> json) {
    final rawMap = json['statusEpochs'];
    final epochs = <String, int>{};
    if (rawMap is Map) {
      for (final e in rawMap.entries) {
        final v = e.value;
        if (v is int) {
          epochs[e.key.toString()] = v;
        } else if (v is num) {
          epochs[e.key.toString()] = v.toInt();
        }
      }
    }
    return ParsedSaFeedTimes(
      statusEpochs: epochs,
      dispatchOrEnRoutePostCount:
          (json['dispatchOrEnRoutePostCount'] as num?)?.toInt() ?? 0,
      earliestStartEpochMs: (json['earliestStartEpochMs'] as num?)?.toInt(),
      earliestDispatchedEpochMs:
          (json['earliestDispatchedEpochMs'] as num?)?.toInt(),
      latestDispatchedEpochMs:
          (json['latestDispatchedEpochMs'] as num?)?.toInt(),
    );
  }

  /// Post epoch (ms) per status name (`Spotted`, `Scheduled`, `Dispatched`, `En Route`,
  /// `On Location`, `Tow Loaded`, `In Tow`, `Cleared`, `Complete`, `Tow Complete`, `Canceled`).
  final Map<String, int> statusEpochs;

  /// Total count of `Dispatched` / `En Route` transitions (> 2 indicates reassignment).
  final int dispatchOrEnRoutePostCount;

  /// Earliest timestamp across any `Spotted`, `Scheduled`, or `Dispatched` transition
  /// (including when `Spotted` or `Scheduled` appears as the `from` status).
  final int? earliestStartEpochMs;

  final int? earliestDispatchedEpochMs;
  final int? latestDispatchedEpochMs;

  bool get wasReassigned => dispatchOrEnRoutePostCount > 2;

  bool get hasTerminalStatus =>
      statusEpochs.containsKey('Cleared') ||
      statusEpochs.containsKey('Tow Complete') ||
      statusEpochs.containsKey('Complete') ||
      statusEpochs.containsKey('Completed') ||
      statusEpochs.containsKey('Canceled') ||
      statusEpochs.containsKey('Cancelled') ||
      statusEpochs.containsKey('Cannot Complete');

  Map<String, dynamic> toJson() => {
    'statusEpochs': statusEpochs,
    'dispatchOrEnRoutePostCount': dispatchOrEnRoutePostCount,
    'earliestStartEpochMs': earliestStartEpochMs,
    'earliestDispatchedEpochMs': earliestDispatchedEpochMs,
    'latestDispatchedEpochMs': latestDispatchedEpochMs,
  };
}

/// Parsed fields from `fsl__vf0999_workorderlightbox`.
class ParsedWorkOrderLightbox {
  const ParsedWorkOrderLightbox({
    this.memberName,
    this.benefitLevel,
    this.workType,
  });

  factory ParsedWorkOrderLightbox.fromJson(Map<String, dynamic> json) {
    return ParsedWorkOrderLightbox(
      memberName: json['memberName'] as String?,
      benefitLevel: json['benefitLevel'] as String?,
      workType: json['workType'] as String?,
    );
  }

  final String? memberName;
  final String? benefitLevel;
  final String? workType;

  Map<String, dynamic> toJson() => {
    'memberName': memberName,
    'benefitLevel': benefitLevel,
    'workType': workType,
  };
}

/// Pure Dart parser and evaluator for Salesforce FSL Chatter feeds and Lightboxes.
class FslChatterParser {
  const FslChatterParser._();

  static final RegExp _feedTextRe = RegExp(
    r'class="feeditemtext[^"]*"[^>]*>(.*?)</span>',
    dotAll: true,
    caseSensitive: false,
  );

  static final RegExp _feedTimeRe = RegExp(
    r'(Today|Yesterday)\s+at\s+(\d{1,2}):(\d{2})\s*([AP]M)',
    caseSensitive: false,
  );

  static final RegExp _saChangeRe = RegExp(
    r'changed\s+Status\s+from\s+([^.<|]+?)\s+to\s+([^.<|]+?)\s*\.',
    caseSensitive: false,
  );

  static final RegExp _etaRangeRe = RegExp(
    r'ETA[^0-9\n]{0,12}?(\d{1,3})\s*(?:[-–/]|to\b)\s*(\d{1,3})\s*(?:m(?:in)?(?:s|utes?)?)?\b',
    caseSensitive: false,
  );

  static final RegExp _etaSingleRe = RegExp(
    r'ETA[^0-9\n]{0,12}?(\d{1,3})\s*(?:m(?:in)?(?:s|utes?)?)?\b',
    caseSensitive: false,
  );

  static final RegExp _kmi2RangeRe = RegExp(
    r'2\s*nd\s*kmi(?:(?!\d).){0,200}?(\d{1,3})\s*(?:[-–/]|to\b)\s*(\d{1,3})\s*(m(?:in)?(?:s|utes?)?)\b',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _kmi2SingleRe = RegExp(
    r'2\s*nd\s*kmi(?:(?!\d).){0,200}?(\d{1,3})\s*(m(?:in)?(?:s|utes?)?)\b',
    caseSensitive: false,
    dotAll: true,
  );

  static final List<RegExp> _naturalEtaPatterns = [
    RegExp(r'\b(\d{1,3})\s*minutes?\s+out\b', caseSensitive: false),
    RegExp(
      r'\banother\s+(\d{1,3})\s*(m(?:in)?(?:s|utes?)?)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'^\s*(\d{1,3})\s*[-–/]\s*(\d{1,3})\s*(m(?:in)?(?:s|utes?)?)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(\d{1,3})\s*(?:m(?:in)?(?:s|utes?)?\s+)?eta\b',
      caseSensitive: false,
    ),
    RegExp(
      r'will\s+be\s+(?:there|arriving|on\s+scene)\s+in\s+(\d{1,3})(?:\s*(?:[-–/]|to\b)\s*(\d{1,3}))?\s*(m(?:in)?(?:s|utes?)?)\b',
      caseSensitive: false,
    ),
  ];

  static final RegExp _kmiRe = RegExp(r'\bKMI\b|\b2nd\b', caseSensitive: false);

  static final RegExp _woContactRe = RegExp(
    r"Contact(?:\s*\|)+\s*([A-Za-z .,'-]{3,60}?)\s*(?:\||$)",
  );
  static final RegExp _woBenefitRe = RegExp(
    r'Membership Benefit Level(?:\s*\|)+\s*([A-Za-z ]{2,30}?)\s*(?:\||$)',
  );
  static final RegExp _woWorkTypeRe = RegExp(
    r'Work Type(?:\s*\|)+\s*([A-Za-z0-9 ./-]{2,60}?)\s*(?:\||$)',
  );

  /// Converts a `"Today|Yesterday at H:MM AM/PM"` match (printed in US Central time)
  /// to a real UTC epoch millisecond timestamp.
  static int feedPostMatchToEpochMs(RegExpMatch tm, {int? nowEpochMs}) {
    final nowUtc = nowEpochMs != null
        ? DateTime.fromMillisecondsSinceEpoch(nowEpochMs, isUtc: true)
        : DateTime.now().toUtc();
    final offsetHours = FslTimeUtils.centralUtcOffsetHours(nowUtc);
    final centralNow = nowUtc.add(Duration(hours: offsetHours));

    final rawHour = int.tryParse(tm.group(2) ?? '0') ?? 0;
    final minute = int.tryParse(tm.group(3) ?? '0') ?? 0;
    final ampm = (tm.group(4) ?? 'AM').toUpperCase();
    final hour24 = (rawHour % 12) + (ampm == 'PM' ? 12 : 0);

    var wallUtc = DateTime.utc(
      centralNow.year,
      centralNow.month,
      centralNow.day,
      hour24,
      minute,
    );
    if ((tm.group(1) ?? '').toLowerCase() == 'yesterday') {
      wallUtc = wallUtc.subtract(const Duration(days: 1));
    }
    return wallUtc.millisecondsSinceEpoch - (offsetHours * 3600 * 1000);
  }

  /// Parses the newest ETA commitment from a Work Order (`vf0996_workorderchatter`)
  /// or Service Appointment (`vf0993_servicechatter`) HTML feed.
  static ParsedChatterEta? parseEtaFromFeed(
    String htmlBody, {
    int? nowEpochMs,
  }) {
    ParsedChatterEta? best;

    for (final m in _feedTextRe.allMatches(htmlBody)) {
      final rawInner = m.group(1) ?? '';
      final clean = _stripHtmlTags(rawInner);
      if (clean.isEmpty) continue;

      RegExpMatch? em =
          _etaRangeRe.firstMatch(clean) ??
          _etaSingleRe.firstMatch(clean) ??
          _kmi2RangeRe.firstMatch(clean) ??
          _kmi2SingleRe.firstMatch(clean);

      if (em == null) {
        for (final pat in _naturalEtaPatterns) {
          em = pat.firstMatch(clean);
          if (em != null) break;
        }
      }
      if (em == null) continue;

      final matchedText = em.group(0) ?? '';
      var nums = RegExp(r'(?<!\d)(\d{1,3})(?!\d)')
          .allMatches(matchedText)
          .map((nm) => nm.group(1)!)
          .toList();
      if (nums.isEmpty) continue;

      if (RegExp(r'^2\s*nd\s*kmi', caseSensitive: false).hasMatch(matchedText) &&
          nums.length > 1 &&
          nums.first == '2') {
        nums = nums.sublist(1);
      }

      int lo;
      int hi;
      if (nums.length >= 2 &&
          RegExp(r'[-–/]|to\b', caseSensitive: false).hasMatch(matchedText)) {
        lo = int.tryParse(nums[0]) ?? 0;
        hi = int.tryParse(nums[1]) ?? lo;
      } else {
        lo = hi = int.tryParse(nums.last) ?? 0;
      }
      if (lo <= 0 || hi <= 0) continue;
      if (hi < lo) {
        final tmp = lo;
        lo = hi;
        hi = tmp;
      }

      final searchEnd = (m.end + 4000).clamp(0, htmlBody.length);
      final tail = htmlBody.substring(m.end, searchEnd);
      final tm = _feedTimeRe.firstMatch(tail);
      if (tm == null) continue;

      final postedMs = feedPostMatchToEpochMs(tm, nowEpochMs: nowEpochMs);
      final candidate = ParsedChatterEta(
        rawText: matchedText.trim(),
        lowMin: lo,
        highMin: hi,
        postedEpochMs: postedMs,
        lowTargetEpochMs: postedMs + (lo * 60000),
        highTargetEpochMs: postedMs + (hi * 60000),
      );

      if (best == null || candidate.postedEpochMs > best.postedEpochMs) {
        best = candidate;
      }
    }

    return best;
  }

  /// Evaluates whether a [ParsedChatterEta] is valid, should be hidden completely
  /// (posted for a previous driver), or should be flagged as stale/unrealistic.
  ///
  /// Addresses Rework #1:
  /// 1. **Reassigned-Driver ETA (`hideCompletely: true`)**: If the call was reassigned
  ///    and the ETA was posted before the latest `Dispatched` timestamp (allowing a
  ///    2-minute clock rounding buffer), hide it completely.
  /// 2. **Normal Status Progression (`isStale: false`)**: Flipping from `Dispatched`
  ///    to `En Route` on the same driver NEVER marks a valid ETA as stale.
  /// 3. **Same-Driver Placeholder / Unrealistic ETA (`isStale: true`)**:
  ///    - `PRE-DISPATCH`: ETA was posted while the call was still `Scheduled` or
  ///      `> 10 min` before the driver was actually `Dispatched`.
  ///    - `UNREALISTIC`: Based on live GPS distance (`distanceToCallKm`), the promised
  ///      window is physically impossible (e.g. requires `> 85 km/h` straight-line /
  ///      `~110 km/h` metro road speed, or `< 8 min` remaining while still `>= 6 km` away
  ///      and `Dispatched` / `STANDSTILL`).
  ///    - `PLACEHOLDER`: Wide generic placeholder range (`>= 45 min` spread, e.g. `60-120 min`).
  static EtaValidityResult evaluateEtaValidity({
    required ParsedChatterEta eta,
    required String currentStatus,
    required int nowEpochMs,
    int? latestDispatchedEpochMs,
    bool wasReassigned = false,
    double? distanceToCallKm,
    String? movementState,
    bool isDriverBusyOnRap = false,
  }) {
    final minutesPastHigh = (nowEpochMs - eta.highTargetEpochMs) / 60000.0;

    // 1. Expired > 45 minutes ago -> hide historical noise
    if (minutesPastHigh > 45.0 &&
        const {
          'Dispatched',
          'En Route',
          'On Location',
          'Scheduled',
        }.contains(currentStatus)) {
      return const EtaValidityResult(
        hideCompletely: true,
        isStale: false,
      );
    }

    // 2. Posted for a previous driver before a reassignment -> hide completely!
    // Allow 2 minutes (120,000 ms) of grace for Chatter's minute-level timestamp truncation.
    if (wasReassigned &&
        latestDispatchedEpochMs != null &&
        eta.postedEpochMs < (latestDispatchedEpochMs - 2 * 60000)) {
      return const EtaValidityResult(
        hideCompletely: true,
        isStale: false,
      );
    }

    // 3. Same-Driver Stale / Placeholder / Unrealistic checks:
    String? staleReason;

    // Check 3A: Pre-dispatch placeholder (posted while still Scheduled, or >10m before Dispatched)
    if (currentStatus == 'Scheduled' || isDriverBusyOnRap) {
      staleReason = 'PRE-DISPATCH';
    } else if (latestDispatchedEpochMs != null &&
        eta.postedEpochMs < (latestDispatchedEpochMs - 10 * 60000)) {
      staleReason = 'PRE-DISPATCH';
    }

    // Check 3B: Physically unrealistic for the live GPS distance to member
    if (staleReason == null &&
        distanceToCallKm != null &&
        distanceToCallKm >= 3.5 &&
        (currentStatus == 'Dispatched' || currentStatus == 'En Route')) {
      final remainingMin = (eta.highTargetEpochMs - nowEpochMs) / 60000.0;
      // Minimum realistic straight-line travel time in metro traffic (~75 km/h straight-line
      // = ~100 km/h road speed, i.e. ~0.8 min per straight-line km)
      final minRealisticMinutes = distanceToCallKm * 0.75;

      if (eta.highMin < minRealisticMinutes) {
        // Even at the moment it was posted, the total promised minutes couldn't cover the distance
        staleReason = 'UNREALISTIC';
      } else if (remainingMin > 0 && remainingMin < minRealisticMinutes * 0.85) {
        // Remaining time before ETA expires requires impossible speed
        staleReason = 'UNREALISTIC';
      } else if (remainingMin <= 8.0 &&
          distanceToCallKm >= 6.0 &&
          (currentStatus == 'Dispatched' || movementState == 'STANDSTILL')) {
        // Driver isn't even moving and is 6+ km away with <= 8 min left on ETA
        staleReason = 'UNREALISTIC';
      }
    }

    // Check 3C: Wide canned placeholder window (>= 45 min spread, e.g. 45-90 or 60-120 min)
    if (staleReason == null && (eta.highMin - eta.lowMin) >= 45) {
      staleReason = 'PLACEHOLDER';
    }

    final isStale = staleReason != null;
    final isExpired =
        !isStale &&
        minutesPastHigh > 0 &&
        (currentStatus == 'Dispatched' || currentStatus == 'En Route');

    return EtaValidityResult(
      hideCompletely: false,
      isStale: isStale,
      staleReason: staleReason,
      isExpired: isExpired,
      expiredMinutes: isExpired ? minutesPastHigh : 0.0,
    );
  }

  /// Parses status transition timestamps and reassignment counts from `vf0993_servicechatter`.
  static ParsedSaFeedTimes parseStatusTimesFromFeed(
    String htmlBody, {
    int? nowEpochMs,
  }) {
    final noScript = htmlBody.replaceAll(
      RegExp(r'<script.*?</script>', dotAll: true, caseSensitive: false),
      ' ',
    );
    final clean = _stripHtmlTags(noScript);

    final statusEpochs = <String, int>{};
    var dispatchOrEnRouteCount = 0;
    int? earliestStart;
    int? earliestDispatched;
    int? latestDispatched;

    const startStatuses = {'Spotted', 'Scheduled', 'Dispatched'};

    final matches = _saChangeRe.allMatches(clean).toList();
    for (int i = 0; i < matches.length; i++) {
      final m = matches[i];
      final fromStatus = (m.group(1) ?? '').trim();
      final toStatus = (m.group(2) ?? '').trim();
      if (toStatus.isEmpty) continue;

      final nextStart = (i + 1 < matches.length)
          ? matches[i + 1].start
          : clean.length;
      final searchEnd = (m.end + 400).clamp(0, nextStart);
      final tail = clean.substring(m.end, searchEnd);
      RegExpMatch? tm = _feedTimeRe.firstMatch(tail);
      if (tm == null) {
        final prevEnd = (i > 0) ? matches[i - 1].end : 0;
        final searchStart = (m.start - 400).clamp(prevEnd, m.start);
        final head = clean.substring(searchStart, m.start);
        final headMatches = _feedTimeRe.allMatches(head);
        if (headMatches.isNotEmpty) {
          tm = headMatches.last;
        }
      }
      if (tm == null) continue;

      final postedMs = feedPostMatchToEpochMs(tm, nowEpochMs: nowEpochMs);

      if (startStatuses.contains(fromStatus) ||
          startStatuses.contains(toStatus)) {
        if (earliestStart == null || postedMs < earliestStart) {
          earliestStart = postedMs;
        }
      }

      if (fromStatus == 'Spotted' || fromStatus == 'Scheduled') {
        final prevFrom = statusEpochs[fromStatus];
        if (prevFrom == null || postedMs < prevFrom) {
          statusEpochs[fromStatus] = postedMs;
        }
      }

      final existing = statusEpochs[toStatus];
      if (toStatus == 'Spotted' || toStatus == 'Scheduled') {
        if (existing == null || postedMs < existing) {
          statusEpochs[toStatus] = postedMs;
        }
      } else {
        if (existing == null || postedMs > existing) {
          statusEpochs[toStatus] = postedMs;
        }
      }

      if (toStatus == 'Dispatched' || toStatus == 'En Route') {
        dispatchOrEnRouteCount++;
      }
      if (toStatus == 'Dispatched') {
        if (earliestDispatched == null || postedMs < earliestDispatched) {
          earliestDispatched = postedMs;
        }
        if (latestDispatched == null || postedMs > latestDispatched) {
          latestDispatched = postedMs;
        }
      }
    }

    return ParsedSaFeedTimes(
      statusEpochs: statusEpochs,
      dispatchOrEnRoutePostCount: dispatchOrEnRouteCount,
      earliestStartEpochMs: earliestStart,
      earliestDispatchedEpochMs: earliestDispatched,
      latestDispatchedEpochMs: latestDispatched,
    );
  }

  /// Parses KMI / 2nd KMI comments from the Work Order chatter feed.
  static List<String> parseKmiMessages(String woHtmlBody) {
    final out = <String>[];
    for (final m in _feedTextRe.allMatches(woHtmlBody)) {
      final clean = _stripHtmlTags(m.group(1) ?? '');
      if (clean.isNotEmpty && _kmiRe.hasMatch(clean)) {
        out.add(clean.length > 300 ? clean.substring(0, 300) : clean);
      }
    }
    return out;
  }

  /// Parses Contact (Member Name), Membership Benefit Level, and Work Type
  /// from `fsl__vf0999_workorderlightbox`.
  static ParsedWorkOrderLightbox parseWorkOrderLightbox(String htmlBody) {
    final noScript = htmlBody.replaceAll(
      RegExp(r'<script.*?</script>', dotAll: true, caseSensitive: false),
      ' ',
    );
    final pipeText = noScript
        .replaceAll(RegExp(r'<[^>]+>'), ' | ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final contactMatch = _woContactRe.firstMatch(pipeText);
    final benefitMatch = _woBenefitRe.firstMatch(pipeText);
    final workTypeMatch = _woWorkTypeRe.firstMatch(pipeText);

    return ParsedWorkOrderLightbox(
      memberName: contactMatch?.group(1)?.trim(),
      benefitLevel: benefitMatch?.group(1)?.trim(),
      workType: workTypeMatch?.group(1)?.trim(),
    );
  }

  /// Parses drop-off `Street, City` from `fsl__vf002_serviceexpertlightboxform`.
  static String? parseServiceLightboxAddress(String htmlBody) {
    final noScript = htmlBody.replaceAll(
      RegExp(r'<script.*?</script>', dotAll: true, caseSensitive: false),
      ' ',
    );
    final segments = RegExp(r'>([^<>]+)<')
        .allMatches(noScript)
        .map((m) => m.group(1) ?? '')
        .join(' | ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\s+'), ' ');

    final cityStreetMatch = RegExp(
      r'Address\s*\|+\s*Landmark\s*\|+\s*City\s*\|+\s*([^|]+?)\s*\|+\s*Street\s*\|+\s*([^|]+?)\s*\|',
    ).firstMatch(segments);
    if (cityStreetMatch != null) {
      final city = cityStreetMatch.group(1)!.trim();
      final street = cityStreetMatch.group(2)!.trim();
      return '$street, $city';
    }

    final streetOnlyMatch = RegExp(
      r'Street\s*\|+\s*([^|]+?)\s*\|',
    ).firstMatch(segments);
    return streetOnlyMatch?.group(1)?.trim();
  }

  static String _stripHtmlTags(String input) {
    return input
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
