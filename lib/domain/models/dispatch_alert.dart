/// Consolidated built-in alert types for FSL Dispatch Tracker.
///
/// Per audit decisions:
/// - `MEMBER_WAITING` is removed.
/// - `STANDING_STILL` and `FAR_AWAY` are consolidated into a single
///   [DispatchAlertType.standingStill] alert that includes both standstill
///   duration and distance from the pickup location.
enum DispatchAlertType {
  dispatchOverdue('DISPATCH_OVERDUE', 'Dispatch Overdue'),
  standingStill('STANDING_STILL', 'Standing Still'),
  etaExpired('ETA_EXPIRED', 'ETA Expired');

  const DispatchAlertType(this.code, this.label);

  final String code;
  final String label;
}

class DispatchAlert {
  const DispatchAlert({
    required this.type,
    required this.driverName,
    required this.driverId,
    required this.callId,
    required this.appointmentNumber,
    required this.status,
    required this.workType,
    required this.detail,
    required this.sinceEpochMs,
    this.durationMin = 0,
    this.distanceKm,
  });

  final DispatchAlertType type;
  final String driverName;
  final String driverId;
  final String callId;
  final String appointmentNumber;
  final String status;
  final String workType;
  final String detail;
  final int sinceEpochMs;
  final double durationMin;
  final double? distanceKm;
}
