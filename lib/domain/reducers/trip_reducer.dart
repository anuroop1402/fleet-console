/// Builds trips from confirmed geofence transitions.
///
/// Pure, like the geofence reducer, and for the same reason: replay has to be
/// idempotent. Trip ids are derived from `(vehicleId, startedAt)` rather than
/// generated, so reducing the same transitions twice produces the same trips
/// rather than a second set of duplicates.
///
/// The brief's table:
///
/// | Transition | Result |
/// |---|---|
/// | Confirmed exit | Start a trip |
/// | Next confirmed entry | Complete the active trip |
/// | No confirmed entry | Keep it IN PROGRESS |
library;

import '../entities/geofence.dart';

/// Reduces one vehicle's confirmed transitions into trips.
///
/// [transitions] are expected in crossing order; they are sorted defensively
/// because a caller that merges replayed history with live data can easily get
/// this wrong, and the cost of sorting an already-sorted list is nothing.
List<Trip> reduceTrips({
  required String vehicleId,
  required List<ConfirmedTransition> transitions,
}) {
  if (transitions.isEmpty) return const [];

  final ordered = [...transitions]..sort((a, b) {
    final byTime = a.crossedAt.compareTo(b.crossedAt);
    if (byTime != 0) return byTime;
    // An exit is processed before an entry at the same instant: you have to
    // leave somewhere before you arrive somewhere else.
    if (a.kind != b.kind) return a.kind == TransitionKind.exit ? -1 : 1;
    return a.geofenceId.compareTo(b.geofenceId);
  });

  final trips = <Trip>[];
  Trip? active;

  for (final transition in ordered) {
    switch (transition.kind) {
      case TransitionKind.exit:
        if (active != null) {
          // An exit while a trip is already open. The entry that should have
          // closed it was never confirmed — almost always because it happened
          // inside a reporting gap. Closing with an unknown destination is
          // more honest than either dropping the new trip or pretending the
          // old one is still running.
          trips.add(
            _close(
              active,
              endedAt: transition.crossedAt,
              destinationGeofenceId: null,
              destinationVersionId: null,
              unknown: true,
            ),
          );
        }
        active = Trip(
          tripId: tripIdFor(vehicleId, transition.crossedAt),
          vehicleId: vehicleId,
          status: TripStatus.inProgress,
          startedAt: transition.crossedAt,
          originGeofenceId: transition.geofenceId,
          originVersionId: transition.versionId,
          inferredDuringGap: transition.inferredDuringGap,
        );

      case TransitionKind.entry:
        if (active == null) {
          // Arriving somewhere with no trip open. This is the normal state at
          // the start of a log — we simply were not watching when it left.
          // Inventing a trip with a fabricated start would be worse than
          // recording nothing.
          continue;
        }
        trips.add(
          _close(
            active,
            endedAt: transition.crossedAt,
            destinationGeofenceId: transition.geofenceId,
            destinationVersionId: transition.versionId,
            unknown: false,
            inferred: transition.inferredDuringGap,
          ),
        );
        active = null;
    }
  }

  // One active trip per vehicle, and it stays IN PROGRESS. Not an error: the
  // truck is still out there.
  if (active != null) trips.add(active);

  return trips;
}

Trip _close(
  Trip trip, {
  required DateTime endedAt,
  required String? destinationGeofenceId,
  required String? destinationVersionId,
  required bool unknown,
  bool inferred = false,
}) => Trip(
  tripId: trip.tripId,
  vehicleId: trip.vehicleId,
  status: TripStatus.completed,
  startedAt: trip.startedAt,
  originGeofenceId: trip.originGeofenceId,
  originVersionId: trip.originVersionId,
  endedAt: endedAt,
  destinationGeofenceId: destinationGeofenceId,
  destinationVersionId: destinationVersionId,
  destinationUnknown: unknown,
  inferredDuringGap: trip.inferredDuringGap || inferred,
);

/// Deterministic trip identity.
///
/// Derived from the vehicle and the crossing instant rather than generated, so
/// that replaying a log — which is how late packets are applied — reproduces
/// the same ids instead of creating a parallel set of duplicate trips. This is
/// the single line that makes "late packets may revise trip boundaries without
/// producing duplicate trips" true.
String tripIdFor(String vehicleId, DateTime startedAt) =>
    '$vehicleId@${startedAt.toUtc().microsecondsSinceEpoch}';
