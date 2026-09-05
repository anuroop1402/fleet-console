/// A single observed value for one signal, with the time it was measured.
library;

import 'package:equatable/equatable.dart';

import 'signal_kind.dart';

final class SignalReading extends Equatable {
  const SignalReading({
    required this.kind,
    required this.value,
    required this.eventTs,
  });

  final SignalKind kind;
  final double value;

  /// When the *vehicle* measured it. Never when we received it — freshness is
  /// about the truck, not about our network.
  final DateTime eventTs;

  /// How old this reading is at [now]. Can be slightly negative when a vehicle
  /// clock runs a little fast; ingest already rejects implausible skew.
  Duration ageAt(DateTime now) => now.difference(eventTs);

  @override
  List<Object?> get props => [kind, value, eventTs];
}

/// Everything currently known about one vehicle's signals.
///
/// A signal that has never reported is simply absent from [readings] — which is
/// what lets the UI distinguish "—" (never seen) from STALE (seen, too old to
/// trust). Those are different facts and must not collapse into one.
final class VehicleSnapshot extends Equatable {
  const VehicleSnapshot({required this.vehicleId, required this.readings});

  final String vehicleId;
  final Map<SignalKind, SignalReading> readings;

  SignalReading? operator [](SignalKind kind) => readings[kind];

  /// The vehicle-level last ping: the newest event time across *all* signals.
  ///
  /// Null when nothing has ever been reported. This is what the OFFLINE rule
  /// tests, and it is deliberately not per-signal.
  DateTime? get lastPing {
    DateTime? newest;
    for (final reading in readings.values) {
      if (newest == null || reading.eventTs.isAfter(newest)) {
        newest = reading.eventTs;
      }
    }
    return newest;
  }

  @override
  List<Object?> get props => [vehicleId, readings];
}
