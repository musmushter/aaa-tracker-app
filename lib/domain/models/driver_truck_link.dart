enum LinkVerificationSignal {
  gpsAndName('GPS + Name Verified'),
  gpsProximitySwap('GPS Match (Truck Swap)'),
  nameAndActiveMotion('Name + Active Truck'),
  nameOnly('Name Match');

  const LinkVerificationSignal(this.badgeText);
  final String badgeText;
}

/// Represents an automatic multi-signal link between an FSL ServiceResource
/// and a Motive Vehicle.
class DriverTruckLink {
  const DriverTruckLink({
    required this.fslResourceId,
    required this.fslDriverName,
    required this.motiveVehicleId,
    required this.motiveVehicleName,
    required this.motiveUnitNumber,
    required this.signal,
    required this.confidenceScore,
    this.gpsDistanceMeters,
  });

  final String fslResourceId;
  final String fslDriverName;
  final String motiveVehicleId;
  final String motiveVehicleName;
  final String motiveUnitNumber;
  final LinkVerificationSignal signal;

  /// Score from 0.0 to 1.0 indicating match strength.
  final double confidenceScore;

  /// Straight-line distance in meters between FSL LastKnownLocation and Motive ELD GPS.
  final double? gpsDistanceMeters;
}
