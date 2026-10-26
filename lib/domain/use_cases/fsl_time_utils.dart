import 'dart:math' as math;
import 'package:timezone/data/latest_10y.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Utilities for Salesforce FSL wall-clock time normalization, phone extraction,
/// name cleaning, Red Alert hue detection, and Haversine distance.
class FslTimeUtils {
  static bool _tzInitialized = false;
  static late tz.Location _centralLocation;

  static void ensureInitialized() {
    if (_tzInitialized) return;
    tz_data.initializeTimeZones();
    _centralLocation = tz.getLocation('America/Chicago');
    _tzInitialized = true;
  }

  /// Returns the current US-Central UTC offset in hours (e.g. -5 during CDT, -6 during CST).
  static int centralUtcOffsetHours(DateTime utcTime) {
    ensureInitialized();
    final centralDt = tz.TZDateTime.from(utcTime, _centralLocation);
    return centralDt.timeZoneOffset.inHours;
  }

  /// Converts a Salesforce FSL "wall-clock-as-UTC" timestamp (milliseconds)
  /// into true UTC epoch milliseconds.
  ///
  /// Salesforce FSL encodes `SchedStartTime`, `SchedEndTime`, `PTA__c`,
  /// `ActualStartTime`, and `LastKnownLocationDate` as US-Central wall-clock
  /// components stored in a UTC DateTime.
  static int sfWallClockMsToEpochMs(int sfMs) {
    ensureInitialized();
    final asUtc = DateTime.fromMillisecondsSinceEpoch(sfMs, isUtc: true);
    final centralWall = tz.TZDateTime(
      _centralLocation,
      asUtc.year,
      asUtc.month,
      asUtc.day,
      asUtc.hour,
      asUtc.minute,
      asUtc.second,
      asUtc.millisecond,
    );
    return centralWall.millisecondsSinceEpoch;
  }

  /// Converts a true UTC epoch millisecond timestamp into the "wall-clock-as-UTC"
  /// format used by Salesforce FSL `SchedStartTime` / `ActualStartTime`.
  static int epochMsToSfWallClockMs(int epochMs) {
    ensureInitialized();
    final centralDt = tz.TZDateTime.fromMillisecondsSinceEpoch(
      _centralLocation,
      epochMs,
    );
    return DateTime.utc(
      centralDt.year,
      centralDt.month,
      centralDt.day,
      centralDt.hour,
      centralDt.minute,
      centralDt.second,
      centralDt.millisecond,
    ).millisecondsSinceEpoch;
  }

  /// Converts a true UTC epoch millisecond timestamp into the "wall-clock-as-UTC"
  /// format expected by `FSL.ctrl001_Gantt.getDelta` for `minDateMs` / `maxDateMs`.
  static ({int minDateMs, int maxDateMs}) currentCentralDayBoundsWallClockMs({
    DateTime? nowUtc,
  }) {
    ensureInitialized();
    final now = nowUtc ?? DateTime.now().toUtc();
    final centralNow = tz.TZDateTime.from(now, _centralLocation);
    // Start 6 hours before midnight of the current Central day and end 24h after
    // midnight to seamlessly cover cross-midnight calls without calendar drift.
    final startWallAsUtc = DateTime.utc(
      centralNow.year,
      centralNow.month,
      centralNow.day,
    ).subtract(const Duration(hours: 6));
    final endWallAsUtc = DateTime.utc(
      centralNow.year,
      centralNow.month,
      centralNow.day,
    ).add(const Duration(hours: 30));
    return (
      minDateMs: startWallAsUtc.millisecondsSinceEpoch,
      maxDateMs: endWallAsUtc.millisecondsSinceEpoch,
    );
  }

  /// Formats a UTC epoch timestamp in US-Central time (`hh:mm AM/PM`).
  static String formatCentralTime(int epochMs) {
    ensureInitialized();
    final dt = tz.TZDateTime.fromMillisecondsSinceEpoch(
      _centralLocation,
      epochMs,
    );
    final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final amPm = dt.hour >= 12 ? 'PM' : 'AM';
    final hStr = hour12.toString().padLeft(2, '0');
    final mStr = dt.minute.toString().padLeft(2, '0');
    return '$hStr:$mStr $amPm';
  }

  static final RegExp _phoneRegex = RegExp(
    r'(?<!\d)(?:1[-.\s]?)?\(?([2-9]\d{2})\)?[-.\s]*(\d{3})[-.\s]*(\d{4})(?!\d)',
  );

  /// Extracts unique 10-digit US phone numbers from a driver string or contact
  /// field and formats them as `(XXX) XXX-XXXX`.
  static List<String> extractPhones(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    final results = <String>[];
    final seenDigits = <String>{};
    for (final match in _phoneRegex.allMatches(raw)) {
      final area = match.group(1)!;
      final prefix = match.group(2)!;
      final line = match.group(3)!;
      final key = '$area$prefix$line';
      if (seenDigits.add(key)) {
        results.add('($area) $prefix-$line');
      }
    }
    return results;
  }

  static const Set<String> _driverNoiseWords = {
    'all',
    'american',
    'houston',
    'towing',
    'bmw',
    'heart',
    'truck',
    'unit',
    'van',
    'tow',
    'fsl',
    'aaa',
    'shop',
    'temp',
    'unassigned',
    'unknown',
    'driver',
    'hd',
    'gmc',
    'chevy',
    'ford',
    'ram',
    'dodge',
    'peterbilt',
    'kenworth',
    'freightliner',
    'international',
    'hino',
    'isuzu',
    'alpha',
    'bravo',
    'charlie',
    'delta',
    'echo',
    'foxtrot',
    'golf',
    'hotel',
    'india',
    'juliet',
    'kilo',
    'lima',
    'mike',
    'nov',
    'november',
    'oscar',
    'papa',
    'quebec',
    'romio',
    'romeo',
    'sierra',
    'tango',
    'uniform',
    'union',
    'vic',
    'victor',
    'whiskey',
    'xray',
    'yankee',
    'zulu',
    'sam',
    'ls',
    'fb',
    'wl',
    'ht',
    'au',
    'auw',
    'pr',
  };

  /// Extracts a clean human-readable driver name from a raw FSL resource string
  /// or Motive vehicle/driver label, returning `null` if no human name is present
  /// (e.g. `"SHOP () -AUW411"` or `"FB-Truck#20"`).
  static String? tryExtractCleanDriverName(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    var s = raw.trim();

    // Reject raw 15/18-char Salesforce IDs (e.g. "0Hn2R0000008PPeSAM")
    if (RegExp(r'^0H[a-zA-Z0-9]{13,16}$').hasMatch(s)) {
      return null;
    }

    // 1. Strip leading decorative prefixes used on FSL Gantt ('*Andre Wells', '-Dante Fields', '*-100008')
    s = s.replaceFirst(RegExp(r'^[\*\-–\s]+'), '');

    // 2. Remove leading contractor IDs like "100002 - ", "100008 - ", "BSP-135588 - "
    s = s.replaceAll(
      RegExp(r'^\s*(?:[A-Za-z]{1,4}\s*[-–]\s*)?\d{4,8}\s*[-–/]\s*'),
      ' ',
    );

    // Strip any decorative '*' or '-' that followed the contractor ID
    s = s.replaceFirst(RegExp(r'^[\*\-–\s]+'), '');

    // 3. In FSL driver strings, everything from the first "(", "[", or "*"
    //    after the driver's name is call-signs, phone numbers, and contractor IDs.
    final prefixBeforeMeta = s.split(RegExp(r'[\(\[\*]')).first;
    s = prefixBeforeMeta;

    // 4. Strip dispatcher alphabetical sort prefixes like 'zNathan', 'vKelly', 'zQuinn'
    s = s.replaceAllMapped(
      RegExp(r'\b[zv]([A-Z][a-z]{2,})\b'),
      (m) => m.group(1)!,
    );

    // 5. Strip fleet/truck prefixes like "FB-Truck#69-", "Ls-Truck#17-", "WL-Truck#31-"
    s = s.replaceAll(
      RegExp(
        r'\b(?:ls|fb|wl)\s*[-/\s]*truck\s*#?\s*\d*\b',
        caseSensitive: false,
      ),
      ' ',
    );
    s = s.replaceAll(RegExp(r'\btruck\s*#?\s*\d*\b', caseSensitive: false), ' ');
    s = s.replaceAll(
      RegExp(
        r'\ball\s+american\b|\bhouston\s+towing\b',
        caseSensitive: false,
      ),
      ' ',
    );

    // 6. Strip unit codes like -F966, -W293, -AU1016, -AUW411, -P690, -WL282, -PR4356, W301
    s = s.replaceAll(
      RegExp(r'(?:^|[-/\s])\b[A-Z]{1,4}\d{2,5}\b', caseSensitive: false),
      ' ',
    );

    // 7. Strip any remaining digits, phone fragments, or punctuation signs
    s = s.replaceAll(RegExp(r'[^a-zA-Z\s]'), ' ');

    // 8. Filter out fleet noise words while preserving single-letter last initials (e.g. "Leo T")
    final rawTokens = s
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty && !_driverNoiseWords.contains(w.toLowerCase()))
        .toList(growable: false);

    final words = <String>[];
    for (int i = 0; i < rawTokens.length; i++) {
      final w = rawTokens[i];
      if (w.length >= 2 || (words.isNotEmpty && w.length == 1)) {
        final isAllUpper = w == w.toUpperCase();
        final isAllLower = w == w.toLowerCase();
        if (isAllUpper || isAllLower) {
          words.add('${w[0].toUpperCase()}${w.substring(1).toLowerCase()}');
        } else {
          words.add(w);
        }
      }
    }

    if (words.isEmpty) return null;
    return words.join(' ');
  }

  /// Cleans a raw FSL driver resource name (e.g.
  /// `"*Andre Wells (11) **713 555 0108** 832 555 0114"` or
  /// `"Jordan Miles (71)**713 555 0101**832 555 0102 (100001)"`) into a
  /// clean human-readable driver name (`"Andre Wells"`, `"Jordan Miles"`).
  static String cleanDriverName(String? raw) {
    if (raw == null || raw.trim().isEmpty) return 'Unknown Driver';
    final extracted = tryExtractCleanDriverName(raw);
    if (extracted != null && extracted.isNotEmpty) {
      return extracted;
    }
    final trimmed = raw.trim();
    // Preserve short synthetic/callsign identifiers (e.g. "D1", "P1") while hiding raw Salesforce IDs
    if (RegExp(r'^[A-Za-z]{1,3}\d{1,3}[a-z]?$').hasMatch(trimmed)) {
      return trimmed;
    }
    return 'Unknown Driver';
  }

  /// Extracts the unit number suffix from a Motive vehicle name
  /// (e.g., `"Jordan Miles (71) -F966"` -> `"F966"`, `"Ray Mendez(49) W301"` -> `"W301"`).
  static String extractMotiveUnitNumber(String vehicleName) {
    final match = RegExp(
      r'[-/\s]([A-Z]{1,3}\d{2,5})\s*$',
      caseSensitive: false,
    ).firstMatch(vehicleName.trim());
    if (match != null) {
      return match.group(1)!.toUpperCase();
    }
    final truckNumMatch = RegExp(
      r'Truck\s*#?\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(vehicleName);
    if (truckNumMatch != null) {
      return 'Truck #${truckNumMatch.group(1)}';
    }
    return vehicleName.trim();
  }

  /// Determines if a Salesforce Gantt hex color (`GanttColor__c`) represents
  /// a Red Alert priority call (hue <= 45° or >= 345° with sufficient saturation).
  static bool isRedAlertColor(String? hexColor) {
    if (hexColor == null || hexColor.isEmpty) return false;
    final clean = hexColor.replaceAll('#', '').trim();
    if (clean.length != 6) return false;
    final value = int.tryParse(clean, radix: 16);
    if (value == null) return false;

    final r = ((value >> 16) & 0xFF) / 255.0;
    final g = ((value >> 8) & 0xFF) / 255.0;
    final b = (value & 0xFF) / 255.0;

    final maxC = math.max(r, math.max(g, b));
    final minC = math.min(r, math.min(g, b));
    final delta = maxC - minC;

    if (maxC < 0.35) return false;
    final saturation = maxC == 0 ? 0.0 : delta / maxC;
    if (saturation < 0.35) return false;

    double hue = 0;
    if (delta > 0) {
      if (maxC == r) {
        hue = 60.0 * (((g - b) / delta) % 6.0);
      } else if (maxC == g) {
        hue = 60.0 * (((b - r) / delta) + 2.0);
      } else {
        hue = 60.0 * (((r - g) / delta) + 4.0);
      }
    }
    if (hue < 0) hue += 360.0;
    return hue <= 45.0 || hue >= 345.0;
  }

  /// Computes straight-line Haversine distance in meters between two GPS coordinates.
  static double haversineMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusM = 6371000.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusM * c;
  }

  static double _degToRad(double deg) => deg * (math.pi / 180.0);
}
