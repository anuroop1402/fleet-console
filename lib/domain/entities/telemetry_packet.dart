/// One timestamped emission from one vehicle, carrying a subset of signals.
library;

import 'package:equatable/equatable.dart';

import 'signal_kind.dart';

/// A single GPS observation. Carries its own accuracy, because the geofence
/// reducer refuses to make a call it cannot support — a fix accurate to ±300 m
/// cannot decide a 200 m fence.
final class GeoFix extends Equatable {
  const GeoFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMetres,
  });

  final double latitude;
  final double longitude;
  final double accuracyMetres;

  @override
  List<Object?> get props => [latitude, longitude, accuracyMetres];
}

/// One packet as it arrives off the wire.
///
/// [eventTs] is the vehicle's clock — when the reading was taken. The moment we
/// received it is recorded separately at ingest. They are not interchangeable:
/// a backlog dumped after three hours in a basement arrives *now* carrying
/// event times from *then*, and treating it as fresh would be wrong.
final class TelemetryPacket extends Equatable {
  const TelemetryPacket({
    required this.packetId,
    required this.vehicleId,
    required this.eventTs,
    this.signals = const {},
    this.location,
  });

  /// Stable identity for this emission. Used as the final, deterministic
  /// tie-break when two packets share an event time *and* an arrival time, so
  /// that replaying the log always produces the same answer.
  final String packetId;

  final String vehicleId;

  /// When the vehicle says it took these readings. Must be UTC.
  final DateTime eventTs;

  final Map<SignalKind, double> signals;

  final GeoFix? location;

  bool get isEmpty => signals.isEmpty && location == null;

  @override
  List<Object?> get props => [packetId, vehicleId, eventTs, signals, location];
}
