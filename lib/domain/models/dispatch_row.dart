import 'dispatch_alert.dart';
import 'driver_truck_link.dart';

/// Represents an active driver's current call row in the Dispatch Tracker.
class DispatchRow {
  const DispatchRow({
    required this.resourceId,
    required this.driverRawName,
    required this.driverCleanName,
    required this.driverPhones,
    required this.serviceAppointmentId,
    required this.appointmentNumber,
    required this.callId,
    required this.territoryGroup,
    required this.workType,
    required this.status,
    required this.statusDurationMin,
    required this.isChainSecondLeg,
    required this.isRedAlert,
    required this.alerts,
    this.ganttColorHex,
    this.memberVehicle,
    this.pickupAddress,
    this.dropoffAddress,
    this.distanceToCallKm,
    this.gpsAgeMin,
    this.driverLat,
    this.driverLon,
    this.callLat,
    this.callLon,
    this.movementState,
    this.movementDurationMin,
    this.etaText,
    this.etaWindowText,
    this.etaLowMin,
    this.etaHighMin,
    this.etaPostedEpochMs,
    this.etaIsStale = false,
    this.etaStaleReason,
    this.kmiComments = const [],
    this.linkedTruck,
  });

  final String resourceId;
  final String driverRawName;
  final String driverCleanName;
  final List<String> driverPhones;
  final String serviceAppointmentId;
  final String appointmentNumber;
  final String callId;
  final String territoryGroup;
  final String workType;
  final String status;
  final double statusDurationMin;
  final bool isChainSecondLeg;
  final bool isRedAlert;
  final List<DispatchAlert> alerts;

  final String? ganttColorHex;
  final String? memberVehicle;
  final String? pickupAddress;
  final String? dropoffAddress;
  final double? distanceToCallKm;
  final double? gpsAgeMin;
  final double? driverLat;
  final double? driverLon;
  final double? callLat;
  final double? callLon;

  /// e.g. 'MOVING', 'STANDSTILL', 'AT LOC', 'AT DROP OFF', or null.
  final String? movementState;
  final int? movementDurationMin;

  /// Parsed ETA & KMI metadata.
  final String? etaText;
  final String? etaWindowText;
  final int? etaLowMin;
  final int? etaHighMin;
  final int? etaPostedEpochMs;
  final bool etaIsStale;
  final String? etaStaleReason;
  final List<String> kmiComments;

  /// Automatic multi-signal link to a Motive truck, if matched.
  final DriverTruckLink? linkedTruck;

  DispatchRow copyWith({
    DriverTruckLink? linkedTruck,
    bool? etaIsStale,
    String? etaStaleReason,
    String? etaText,
    String? etaWindowText,
    int? etaLowMin,
    int? etaHighMin,
    int? etaPostedEpochMs,
    List<String>? kmiComments,
    String? dropoffAddress,
  }) {
    return DispatchRow(
      resourceId: resourceId,
      driverRawName: driverRawName,
      driverCleanName: driverCleanName,
      driverPhones: driverPhones,
      serviceAppointmentId: serviceAppointmentId,
      appointmentNumber: appointmentNumber,
      callId: callId,
      territoryGroup: territoryGroup,
      workType: workType,
      status: status,
      statusDurationMin: statusDurationMin,
      isChainSecondLeg: isChainSecondLeg,
      isRedAlert: isRedAlert,
      alerts: alerts,
      ganttColorHex: ganttColorHex,
      memberVehicle: memberVehicle,
      pickupAddress: pickupAddress,
      dropoffAddress: dropoffAddress ?? this.dropoffAddress,
      distanceToCallKm: distanceToCallKm,
      gpsAgeMin: gpsAgeMin,
      driverLat: driverLat,
      driverLon: driverLon,
      callLat: callLat,
      callLon: callLon,
      movementState: movementState,
      movementDurationMin: movementDurationMin,
      etaText: etaText ?? this.etaText,
      etaWindowText: etaWindowText ?? this.etaWindowText,
      etaLowMin: etaLowMin ?? this.etaLowMin,
      etaHighMin: etaHighMin ?? this.etaHighMin,
      etaPostedEpochMs: etaPostedEpochMs ?? this.etaPostedEpochMs,
      etaIsStale: etaIsStale ?? this.etaIsStale,
      etaStaleReason: etaStaleReason ?? this.etaStaleReason,
      kmiComments: kmiComments ?? this.kmiComments,
      linkedTruck: linkedTruck ?? this.linkedTruck,
    );
  }
}
