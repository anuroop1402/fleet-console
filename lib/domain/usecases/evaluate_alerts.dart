/// Runs the alert state machine across the whole fleet.
library;

import '../../core/clock.dart';
import '../entities/alert.dart';
import '../entities/signal_reading.dart';
import '../repositories/alert_repository.dart';
import '../rules/alert_rules.dart';

/// What one evaluation pass did. Returned for logging and for tests that care
/// about transitions rather than final state.
final class EvaluationSummary {
  const EvaluationSummary({
    this.opened = 0,
    this.escalated = 0,
    this.deEscalated = 0,
    this.resolved = 0,
    this.markedStale = 0,
    this.unDismissed = 0,
  });

  final int opened;
  final int escalated;
  final int deEscalated;
  final int resolved;
  final int markedStale;

  /// Dismissals broken by an escalation. Worth counting separately: it is the
  /// one transition that makes something reappear after a human hid it, so if
  /// it ever fires unexpectedly it needs to be findable.
  final int unDismissed;

  bool get isQuiet =>
      opened == 0 &&
      escalated == 0 &&
      deEscalated == 0 &&
      resolved == 0 &&
      markedStale == 0;

  @override
  String toString() =>
      'opened $opened, escalated $escalated, de-escalated $deEscalated, '
      'resolved $resolved, stale $markedStale, un-dismissed $unDismissed';
}

/// Evaluates every alert kind for every vehicle and persists the result.
///
/// Called after ingest, and again whenever alerts are read. There is no
/// background timer: some transitions are driven purely by the clock — a fresh
/// alert becomes stale with no new packet at all — and waking a phone
/// periodically to change a pill from red to grey is a poor trade against
/// computing it when someone actually looks.
final class EvaluateAlerts {
  const EvaluateAlerts({
    required AlertRepository alerts,
    required FleetSnapshotSource snapshots,
    required Clock clock,
  }) : _alerts = alerts,
       _snapshots = snapshots,
       _clock = clock;

  final AlertRepository _alerts;
  final FleetSnapshotSource _snapshots;
  final Clock _clock;

  Future<EvaluationSummary> call() async {
    // One instant for the entire sweep. Reading the clock per vehicle would let
    // two trucks with identical readings get different answers because the
    // sweep took a few milliseconds.
    final now = _clock.nowUtc();

    final snapshots = await _snapshots.allVehicleSnapshots();
    final open = await _alerts.openAlerts();

    // Index by (vehicle, kind). At most one open alert per pair is an invariant
    // of this loop: a new instance is only created when none is open.
    final currentByKey = <String, Alert>{
      for (final alert in open) _key(alert.vehicleId, alert.kind): alert,
    };

    final upserts = <Alert>[];
    final resolved = <Alert>[];
    var opened = 0;
    var escalated = 0;
    var deEscalated = 0;
    var markedStale = 0;
    var unDismissed = 0;

    // Every vehicle that has an open alert *or* a snapshot. A vehicle whose
    // readings vanished still needs evaluating, or its alert would be stranded
    // and never even marked stale.
    final vehicleIds = <String>{...snapshots.keys, ...open.map((a) => a.vehicleId)};

    for (final vehicleId in vehicleIds) {
      final snapshot =
          snapshots[vehicleId] ??
          VehicleSnapshot(vehicleId: vehicleId, readings: const {});

      for (final kind in AlertKind.values) {
        final key = _key(vehicleId, kind);
        final current = currentByKey[key];

        final evaluation = evaluateAlert(
          current: current,
          observation: _observe(kind, snapshot, now),
          kind: kind,
          vehicleId: vehicleId,
          now: now,
        );

        switch (evaluation.transition) {
          case AlertTransition.none:
            break;
          case AlertTransition.resolved:
            if (current != null) resolved.add(current);
          case AlertTransition.opened:
            opened++;
            upserts.add(evaluation.alert!);
          case AlertTransition.escalated:
            escalated++;
            if (current!.isDismissed && !evaluation.alert!.isDismissed) {
              unDismissed++;
            }
            upserts.add(evaluation.alert!);
          case AlertTransition.deEscalated:
            deEscalated++;
            upserts.add(evaluation.alert!);
          case AlertTransition.markedStale:
            markedStale++;
            upserts.add(evaluation.alert!);
          case AlertTransition.unchanged:
            // Still written: last_known_value and the staleness flag can move
            // without the severity changing, and the screen shows both.
            upserts.add(evaluation.alert!);
        }
      }
    }

    await _alerts.applyTransitions(
      upserts: upserts,
      resolved: resolved,
      now: now,
    );

    return EvaluationSummary(
      opened: opened,
      escalated: escalated,
      deEscalated: deEscalated,
      resolved: resolved.length,
      markedStale: markedStale,
      unDismissed: unDismissed,
    );
  }

  ConditionObservation _observe(
    AlertKind kind,
    VehicleSnapshot snapshot,
    DateTime now,
  ) => switch (kind) {
    AlertKind.batterySoc => observeSoc(snapshot, now),
    AlertKind.batteryOverheating => observeBatteryTemperature(snapshot, now),
  };

  static String _key(String vehicleId, AlertKind kind) =>
      '$vehicleId|${kind.wireName}';
}
