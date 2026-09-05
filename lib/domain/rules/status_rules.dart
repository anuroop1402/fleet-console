/// The status chip rule, first match wins.
library;

import '../entities/signal_kind.dart';
import '../entities/signal_reading.dart';
import '../entities/vehicle_status.dart';
import 'staleness.dart';

/// Classifies a vehicle from its current snapshot.
///
/// The brief's table, in order: OFFLINE if the vehicle-level last ping is older
/// than ten minutes; MOVING if speed > 0; IDLE if speed = 0 and ignition on;
/// STOPPED if ignition off.
///
/// Two things the table leaves open, resolved here and documented in docs/01:
///
/// **Stale readings do not classify.** Speed and ignition are consulted only
/// while *fresh*. A vehicle whose odometer pinged a minute ago but whose last
/// speed reading is forty minutes old is online, yet we have no idea whether it
/// is moving. Reading MOVING off a forty-minute-old speed would contradict the
/// verdict pill on the very same screen, which shows that reading as STALE and
/// explicitly makes no claim. The screen has to agree with itself.
///
/// **What is left over is [VehicleStatus.unknown].** Packets carry a subset of
/// signals, so "online but nothing fresh to classify" is a real state, not a
/// theoretical one. Falling through to STOPPED would assert ignition off from
/// an absence of evidence.
VehicleStatus statusOf(VehicleSnapshot snapshot, DateTime now) {
  if (!isVehicleOnline(snapshot.lastPing, now)) return VehicleStatus.offline;

  final speed = _freshValue(snapshot, SignalKind.speed, now);
  if (speed != null && speed > 0) return VehicleStatus.moving;

  final ignitionOn = _freshValue(snapshot, SignalKind.ignition, now)
      ?.asIgnition;

  if (speed != null && speed == 0 && ignitionOn == true) {
    return VehicleStatus.idle;
  }

  if (ignitionOn == false) return VehicleStatus.stopped;

  return VehicleStatus.unknown;
}

/// The value of a signal, but only if it is fresh enough to act on.
double? _freshValue(
  VehicleSnapshot snapshot,
  SignalKind kind,
  DateTime now,
) {
  final reading = snapshot[kind];
  if (reading == null) return null;
  return isFresh(reading.eventTs, now) ? reading.value : null;
}
