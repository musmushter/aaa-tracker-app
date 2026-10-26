/// Represents a completed, canceled, or unable-to-complete call in the Callback Log.
///
/// Includes all 10 standard columns (`Cleared`, `Call`, `Member`, `Member phone`,
/// `Benefit level`, `Type`, `Vehicle`, `Driver`, `Member waited`, `On scene`) plus
/// the 3 required indicators:
/// 1. `territory` — Service territory / contractor group
/// 2. `isRedAlert` — High-risk Red Alert color from Gantt (`GanttColor__c`)
/// 3. `isCancelled` — Cancelled / Unable to Complete indicator (most prominent)
class ClearedCall {
  const ClearedCall({
    required this.serviceAppointmentId,
    required this.appointmentNumber,
    required this.callId,
    required this.status,
    required this.driverName,
    required this.clearedAtEpochMs,
    this.territory = '',
    this.isRedAlert = false,
    this.isCancelled = false,
    this.ganttColorHex,
    this.schedStartEpochMs,
    this.workOrderId,
    this.workType,
    this.memberName,
    this.memberPhone,
    this.benefitLevel,
    this.memberVehicle,
    this.waitDurationMin,
    this.onSceneDurationMin,
    this.wasReassigned = false,
    this.calledBack = false,
  });

  final String serviceAppointmentId;
  final String appointmentNumber;
  final String callId;
  final String status;
  final String driverName;
  final int clearedAtEpochMs;

  /// New Indicator #1: Service Territory / Group
  final String territory;

  /// New Indicator #2: Red Alert (`GanttColor__c` red/orange hue)
  final bool isRedAlert;

  /// New Indicator #3 (Most Important): Whether the service was cancelled
  final bool isCancelled;

  final String? ganttColorHex;
  final int? schedStartEpochMs;
  final String? workOrderId;
  final String? workType;
  final String? memberName;
  final String? memberPhone;
  final String? benefitLevel;
  final String? memberVehicle;
  final int? waitDurationMin;
  final int? onSceneDurationMin;
  final bool wasReassigned;
  final bool calledBack;

  /// Unique key per `(callId, driverName)` pair, matching `tracker.py`'s deduplication.
  String get uniqueKey => '${callId}_$driverName';

  ClearedCall copyWith({
    String? status,
    int? clearedAtEpochMs,
    String? territory,
    bool? isRedAlert,
    bool? isCancelled,
    String? ganttColorHex,
    int? schedStartEpochMs,
    String? workType,
    String? memberName,
    String? memberPhone,
    String? benefitLevel,
    String? memberVehicle,
    int? waitDurationMin,
    int? onSceneDurationMin,
    bool? wasReassigned,
    bool? calledBack,
  }) {
    return ClearedCall(
      serviceAppointmentId: serviceAppointmentId,
      appointmentNumber: appointmentNumber,
      callId: callId,
      status: status ?? this.status,
      driverName: driverName,
      clearedAtEpochMs: clearedAtEpochMs ?? this.clearedAtEpochMs,
      territory: territory ?? this.territory,
      isRedAlert: isRedAlert ?? this.isRedAlert,
      isCancelled: isCancelled ?? this.isCancelled,
      ganttColorHex: ganttColorHex ?? this.ganttColorHex,
      schedStartEpochMs: schedStartEpochMs ?? this.schedStartEpochMs,
      workOrderId: workOrderId,
      workType: workType ?? this.workType,
      memberName: memberName ?? this.memberName,
      memberPhone: memberPhone ?? this.memberPhone,
      benefitLevel: benefitLevel ?? this.benefitLevel,
      memberVehicle: memberVehicle ?? this.memberVehicle,
      waitDurationMin: waitDurationMin ?? this.waitDurationMin,
      onSceneDurationMin: onSceneDurationMin ?? this.onSceneDurationMin,
      wasReassigned: wasReassigned ?? this.wasReassigned,
      calledBack: calledBack ?? this.calledBack,
    );
  }
}
