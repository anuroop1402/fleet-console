/// Freshness, and the verdict pill that follows from it.
library;

import '../../core/constants.dart';
import '../entities/signal_kind.dart';
import '../entities/signal_reading.dart';
import '../entities/verdict.dart';

/// Whether a reading is recent enough to make a claim about.
///
/// [now] is passed in, never read. Every caller is a rule or a use case that
/// already has an injected clock.
bool isFresh(DateTime eventTs, DateTime now) =>
    now.difference(eventTs) <= FleetThresholds.signalStaleAfter;

/// Whether a vehicle has reported anything at all inside the offline window.
///
/// Vehicle-level: [lastPing] is the newest event time across *all* signals, not
/// one signal's age. A vehicle reporting only its odometer is still online.
bool isVehicleOnline(DateTime? lastPing, DateTime now) =>
    lastPing != null &&
    now.difference(lastPing) <= FleetThresholds.offlineAfter;

/// Whether a signal's value breaches its threshold.
///
/// Returns null for signals that have no threshold — speed, odometer, range and
/// ignition are reported, not judged. A null here means "no opinion", which is
/// different from "within limits", though both render as NORMAL.
bool? breachesThreshold(SignalKind kind, double value) => switch (kind) {
  SignalKind.soc => value < FleetThresholds.socWarningPercent,
  SignalKind.batteryTemp =>
    value > FleetThresholds.batteryTempCriticalCelsius,
  SignalKind.speed ||
  SignalKind.odometer ||
  SignalKind.rangeKm ||
  SignalKind.ignition => null,
};

/// The pill for one row of the readings register.
///
/// The ordering is the whole rule: absence is checked before age, and age is
/// checked before the threshold. A stale reading never produces NORMAL or
/// ALERT, because the brief is explicit that STALE makes no such claim — an
/// eight-hour-old 5% SOC is not evidence the battery is flat *now*, and
/// pretending otherwise would put a red pill on a vehicle we simply cannot see.
Verdict verdictFor({
  required SignalKind kind,
  required SignalReading? reading,
  required DateTime now,
}) {
  if (reading == null) return Verdict.neverReported;
  if (!isFresh(reading.eventTs, now)) return Verdict.stale;
  return breachesThreshold(kind, reading.value) ?? false
      ? Verdict.alert
      : Verdict.normal;
}
