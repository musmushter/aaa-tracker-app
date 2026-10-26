import '../models/dispatch_alert.dart';
import '../models/dispatch_row.dart';
import 'fsl_time_utils.dart';

/// Builds the standalone Dispatch Tracker text report for clipboard copying,
/// matching `fsl_tracker/dashboard.html` (`buildReport`) with clean driver names.
class DispatchReportBuilder {
  static const int _justLateMs = 3 * 60000;

  static String buildReport(DispatchRow row, {int? nowEpochMs}) {
    final nowMs = nowEpochMs ?? DateTime.now().millisecondsSinceEpoch;
    final cleanDriver =
        FslTimeUtils.tryExtractCleanDriverName(row.driverCleanName) ??
        FslTimeUtils.cleanDriverName(row.driverRawName);

    final red = row.isRedAlert ? ' RED ALERT SERVICE' : '';
    final head = '$cleanDriver ${row.callId}$red';
    final statusMin = row.statusDurationMin.round();
    final parts = <String>['${row.status} for $statusMin mins'];

    final loTargetMs =
        (row.etaPostedEpochMs != null && row.etaLowMin != null)
        ? row.etaPostedEpochMs! + (row.etaLowMin! * 60000)
        : null;
    final hiTargetMs =
        (row.etaPostedEpochMs != null && row.etaHighMin != null)
        ? row.etaPostedEpochMs! + (row.etaHighMin! * 60000)
        : null;

    final hasEtaExpiredAlert = row.alerts.any(
      (a) => a.type == DispatchAlertType.etaExpired,
    );
    final int? lateMin =
        (!row.etaIsStale && loTargetMs != null && hiTargetMs != null)
        ? ((nowMs - hiTargetMs) / 60000.0).round()
        : null;
    final bool isLate =
        (lateMin != null && lateMin > 0) ||
        (hasEtaExpiredAlert && !row.etaIsStale);

    if (!isLate) {
      if (!row.etaIsStale &&
          !row.isChainSecondLeg &&
          loTargetMs != null &&
          hiTargetMs != null) {
        final minsUntilStart = ((loTargetMs - nowMs) / 60000.0).round();
        if (minsUntilStart > 0) {
          parts.add('ETA $minsUntilStart mins');
        } else if (hiTargetMs > nowMs) {
          parts.add('ETA arriving now');
        } else {
          parts.add('no ETA');
        }
      } else {
        parts.add('no ETA');
      }

      final tail = <String>['not answering'];
      String? moveLine;
      if (row.movementState == 'STANDSTILL' && row.status == 'En Route') {
        final still =
            (row.movementDurationMin != null && row.movementDurationMin! >= 3)
            ? row.movementDurationMin!
            : statusMin;
        tail.add('not moving for $still mins');
      } else if (row.movementState == 'STANDSTILL' &&
          row.status == 'Dispatched') {
        tail.add('not moving on map');
      } else if ((row.movementState == 'MOVING' &&
              row.status == 'Dispatched') ||
          ((row.movementState == 'AT LOC' ||
                  row.movementState == 'AT DROP OFF') &&
              (row.status == 'Dispatched' || row.status == 'En Route'))) {
        moveLine = "He is moving but didn't change status";
      }

      parts.add(tail.join(' and '));
      return '$head ${parts.join(' ')}${moveLine != null ? '\n$moveLine' : ''}';
    }

    // Late-ETA multi-line format (matching dashboard.html lines 388-401)
    final bool justLate =
        hiTargetMs != null && (nowMs - hiTargetMs) <= _justLateMs;
    var lateLine = justLate
        ? 'ETA just exceeded'
        : 'He exceeded ETA ${lateMin ?? 1} mins ago';
    if (row.distanceToCallKm != null && row.distanceToCallKm! > 3.3) {
      lateLine += ' and not close to srv';
    }
    return '$head ${parts.join(' ')}\n$lateLine\nMbr needs an update on ETA';
  }
}
