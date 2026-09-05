/// Persistence for alerts, expressed without naming a database.
library;

import '../entities/alert.dart';
import '../entities/fleet_view.dart';
import '../entities/signal_reading.dart';

abstract interface class AlertRepository {
  /// Every alert that has not resolved, dismissed ones included.
  ///
  /// Dismissed alerts are still *open*: the condition persists, a human just
  /// chose not to look at it. They have to come back so the state machine can
  /// escalate them, which is the whole point of remembering the severity at
  /// which they were dismissed.
  Future<List<Alert>> openAlerts();

  /// Open, undismissed alerts — what the alerts screen shows.
  ///
  /// Returns the display view rather than bare alerts, because a screen that
  /// names trucks by internal id is useless to the person holding a clipboard.
  Future<List<AlertView>> visibleAlerts();

  /// Writes the results of one evaluation pass.
  ///
  /// Takes the whole set rather than one at a time so the pass is a single
  /// transaction: an evaluation that half-applied would leave alerts that
  /// disagree with the readings they were derived from.
  Future<void> applyTransitions({
    required List<Alert> upserts,
    required List<Alert> resolved,
    required DateTime now,
  });

  Future<void> saveDismissal(Alert alert);

  /// Alert history for one vehicle, newest first, resolved ones included.
  Future<List<Alert>> alertHistory(String vehicleId, {int limit});
}

/// Readings for the whole fleet in one read.
///
/// Alert evaluation is a fleet-wide sweep, so fetching per vehicle would be 500
/// round-trips to the connection isolate. This is on [FleetSnapshotSource]
/// rather than [AlertRepository] because it is about readings, not alerts.
abstract interface class FleetSnapshotSource {
  Future<Map<String, VehicleSnapshot>> allVehicleSnapshots();
}
