/// The alert state machine.
///
/// A pure function of (what is currently open, what we can currently observe).
/// No clock reads, no I/O — `now` arrives as an argument so that every
/// transition in docs/01 §3 can be asserted directly.
library;

import '../../core/constants.dart';
import '../entities/alert.dart';
import '../entities/signal_kind.dart';
import '../entities/signal_reading.dart';
import 'staleness.dart';

/// What we can currently say about a condition.
///
/// Three states, not two. "Not firing" and "cannot see" are different facts,
/// and collapsing them is precisely the bug this type exists to prevent: a
/// stale reading is not evidence the problem went away.
sealed class ConditionObservation {
  const ConditionObservation();
}

/// The condition is currently met, at this severity, on a fresh reading.
final class ConditionFiring extends ConditionObservation {
  const ConditionFiring(this.severity, this.value, this.observedAt);

  final AlertSeverity severity;
  final double value;
  final DateTime observedAt;
}

/// A fresh reading says the condition is not met.
final class ConditionClear extends ConditionObservation {
  const ConditionClear(this.value, this.observedAt);

  final double value;
  final DateTime observedAt;
}

/// No fresh reading. We are not claiming anything either way.
final class ConditionUnobservable extends ConditionObservation {
  const ConditionUnobservable({this.lastKnownValue, this.lastKnownAt});

  final double? lastKnownValue;
  final DateTime? lastKnownAt;
}

/// What [evaluateAlert] decided, for logging and for tests that care about the
/// transition rather than the resulting state.
enum AlertTransition {
  /// Nothing was open and nothing fired.
  none,

  /// A new instance opened.
  opened,

  /// Same instance, severity increased.
  escalated,

  /// Same instance, severity decreased.
  deEscalated,

  /// The condition cleared on a fresh reading. The instance is closed.
  resolved,

  /// Still open, but the reading behind it went stale.
  markedStale,

  /// Still open, still visible, nothing changed.
  unchanged,
}

/// The outcome of one evaluation. [alert] is null when nothing is open.
final class AlertEvaluation {
  const AlertEvaluation(this.transition, this.alert);

  final AlertTransition transition;
  final Alert? alert;
}

/// Reads the SOC condition off a snapshot.
///
/// The two SOC thresholds are **one** escalating condition, so this returns a
/// single observation whose severity moves between warning and critical rather
/// than two independent alerts.
ConditionObservation observeSoc(VehicleSnapshot snapshot, DateTime now) =>
    _observe(
      snapshot: snapshot,
      now: now,
      kind: SignalKind.soc,
      severityFor: (soc) => switch (soc) {
        < FleetThresholds.socCriticalPercent => AlertSeverity.critical,
        < FleetThresholds.socWarningPercent => AlertSeverity.warning,
        _ => null,
      },
    );

ConditionObservation observeBatteryTemperature(
  VehicleSnapshot snapshot,
  DateTime now,
) => _observe(
  snapshot: snapshot,
  now: now,
  kind: SignalKind.batteryTemp,
  severityFor: (celsius) =>
      celsius > FleetThresholds.batteryTempCriticalCelsius
      ? AlertSeverity.critical
      : null,
);

ConditionObservation _observe({
  required VehicleSnapshot snapshot,
  required DateTime now,
  required SignalKind kind,
  required AlertSeverity? Function(double) severityFor,
}) {
  final reading = snapshot[kind];
  if (reading == null) return const ConditionUnobservable();

  // Thresholds apply "on fresh readings only" — the brief's words. A stale
  // reading yields Unobservable, never Clear.
  if (!isFresh(reading.eventTs, now)) {
    return ConditionUnobservable(
      lastKnownValue: reading.value,
      lastKnownAt: reading.eventTs,
    );
  }

  final severity = severityFor(reading.value);
  return severity == null
      ? ConditionClear(reading.value, reading.eventTs)
      : ConditionFiring(severity, reading.value, reading.eventTs);
}

/// Advances one alert kind by one observation.
///
/// The four cases the brief leaves open, and the reasoning, all live here:
///
/// 1. **Dismissed at warning, then escalates to critical → it comes back.**
///    Escalation is new information. Silencing a warning is not consent to
///    silence a critical.
/// 2. **Dismissed at critical, then recovers to warning → it stays dismissed,
///    at the lower severity.** Severity describes the current condition, but
///    the human said "I am on it" about a battery problem that still exists.
/// 3. **Condition clears → resolved, regardless of dismissal.** The brief says
///    so explicitly. A later re-fire opens a *new* instance with a new
///    `openedAt`, because a new occurrence deserves a fresh decision.
/// 4. **Reading goes stale while open → stays open, flagged.** Resolving would
///    assert the condition cleared, which we cannot see. Silence about a
///    possibly-burning truck is the worse error.
AlertEvaluation evaluateAlert({
  required Alert? current,
  required ConditionObservation observation,
  required AlertKind kind,
  required String vehicleId,
  required DateTime now,
}) {
  switch (observation) {
    case ConditionClear():
      // Case 3. Resolution is independent of dismissal.
      return AlertEvaluation(
        current == null ? AlertTransition.none : AlertTransition.resolved,
        null,
      );

    case ConditionUnobservable(:final lastKnownValue, :final lastKnownAt):
      if (current == null) {
        // Nothing open and nothing visible. Silence is correct here — we have
        // no reason to believe there is a problem.
        return const AlertEvaluation(AlertTransition.none, null);
      }
      // Case 4.
      final staleAlert = current.copyWith(
        isConditionStale: true,
        lastKnownValue: lastKnownValue ?? current.lastKnownValue,
        lastKnownAt: lastKnownAt ?? current.lastKnownAt,
      );
      return AlertEvaluation(
        current.isConditionStale
            ? AlertTransition.unchanged
            : AlertTransition.markedStale,
        staleAlert,
      );

    case ConditionFiring(:final severity, :final value, :final observedAt):
      if (current == null) {
        return AlertEvaluation(
          AlertTransition.opened,
          Alert(
            vehicleId: vehicleId,
            kind: kind,
            severity: severity,
            openedAt: observedAt,
            lastKnownValue: value,
            lastKnownAt: observedAt,
          ),
        );
      }

      // A dismissal holds only while the condition stays at or below the
      // severity it was dismissed at. This single comparison is what
      // distinguishes case 1 from case 2.
      final dismissalBroken =
          current.isDismissed &&
          current.dismissedAtSeverity != null &&
          severity.isWorseThan(current.dismissedAtSeverity!);

      final updated = current.copyWith(
        severity: severity,
        isConditionStale: false,
        lastKnownValue: value,
        lastKnownAt: observedAt,
        clearDismissal: dismissalBroken,
      );

      final transition = switch (severity.rank - current.severity.rank) {
        > 0 => AlertTransition.escalated,
        < 0 => AlertTransition.deEscalated,
        // Same severity. Covers the case where a stale alert becomes
        // observable again at the severity it already had: the staleness flag
        // is cleared above, but nothing about the alert itself changed.
        _ => AlertTransition.unchanged,
      };

      return AlertEvaluation(transition, updated);
  }
}

/// Records a human dismissing an alert.
///
/// The severity at dismissal is captured, because that is what a later
/// escalation is compared against.
Alert dismiss(Alert alert, DismissalReason reason, DateTime now) =>
    alert.copyWith(
      dismissedAt: now,
      dismissedAtSeverity: alert.severity,
      dismissalReason: reason,
    );

/// Restores an alert dismissed within the undo window.
///
/// Dismissal is persisted immediately and undo removes it, rather than the
/// dismissal being deferred for five seconds. If the app is killed mid-undo the
/// alert stays dismissed — the durable reading of what the user actually did.
Alert undoDismissal(Alert alert) => alert.copyWith(clearDismissal: true);

/// Whether [alert] is still inside its undo window at [now].
bool canUndo(Alert alert, DateTime now) {
  final dismissedAt = alert.dismissedAt;
  if (dismissedAt == null) return false;
  return now.difference(dismissedAt) <= FleetThresholds.undoWindow;
}
