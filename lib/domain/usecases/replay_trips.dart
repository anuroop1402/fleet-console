/// Rebuilds the derived tables by replaying the fix log.
///
/// `geofence_visits` and `trips` are a pure function of
/// (location_fixes × geofence_versions). This use case is the only thing that
/// writes them, and it does so by *recomputation*, never by patching.
///
/// Why recomputation rather than incremental patching: new information can
/// arrive about the past. A late fix does not merely append — it can move a
/// crossing earlier, split one trip into two, or supply the destination for a
/// trip that was in progress. Working out which existing rows each of those
/// affects is a combinatorial repair problem, and every uncovered combination
/// is a silent data bug. Replaying a bounded window is more work per packet and
/// far less work to be confident in.
library;

import '../../core/clock.dart';
import '../../core/constants.dart';
import '../entities/geofence.dart';
import '../reducers/geofence_reducer.dart';
import '../reducers/trip_reducer.dart';
import '../repositories/geofence_repository.dart';

/// What one replay produced.
final class ReplayResult {
  const ReplayResult({
    required this.vehiclesReplayed,
    required this.transitions,
    required this.visits,
    required this.trips,
    required this.rejectedFixes,
  });

  static const empty = ReplayResult(
    vehiclesReplayed: 0,
    transitions: 0,
    visits: 0,
    trips: 0,
    rejectedFixes: 0,
  );

  final int vehiclesReplayed;
  final int transitions;
  final int visits;
  final int trips;
  final int rejectedFixes;

  @override
  String toString() =>
      'replayed $vehiclesReplayed vehicles -> $transitions transitions, '
      '$visits visits, $trips trips ($rejectedFixes fixes rejected)';
}

/// Writes the output of a replay. Implemented in the data layer.
abstract interface class DerivedTripWriter {
  /// Replaces all derived rows for [vehicleId] whose event time is at or after
  /// [from] with the supplied rows, in one transaction.
  ///
  /// Delete-then-insert rather than upsert, because a replay can legitimately
  /// produce *fewer* rows than before — a late fix that reveals a truck never
  /// really left removes a trip that used to exist. An upsert would leave that
  /// stale row behind for ever.
  Future<void> replaceDerived({
    required String vehicleId,
    required DateTime from,
    required List<GeofenceVisit> visits,
    required List<Trip> trips,
  });
}

final class ReplayTrips {
  const ReplayTrips({
    required LocationFixSource fixes,
    required GeofenceRepository geofences,
    required DerivedTripWriter writer,
    required Clock clock,
  }) : _fixes = fixes,
       _geofences = geofences,
       _writer = writer,
       _clock = clock;

  final LocationFixSource _fixes;
  final GeofenceRepository _geofences;
  final DerivedTripWriter _writer;
  final Clock _clock;

  /// Replays every vehicle that has reported since [since].
  ///
  /// Defaults to the raw-fix retention window, because that is the replay
  /// horizon: derived state is rebuilt from raw fixes, so we can only rebuild
  /// as far back as raw fixes still exist. Compacting more aggressively buys
  /// disk and costs the ability to correct the past — the two are the same
  /// knob, not two independent settings.
  Future<ReplayResult> call({DateTime? since, List<String>? vehicleIds}) async {
    final now = _clock.nowUtc();
    final horizon =
        since ?? now.subtract(RetentionPolicy.rawLocationFixes);

    final targets =
        vehicleIds ?? await _fixes.vehiclesWithFixesSince(horizon);
    if (targets.isEmpty) return ReplayResult.empty;

    // Loaded once for the whole pass. Every version, not just the current
    // ones: a fix from three weeks ago must be judged against the fence as it
    // was three weeks ago.
    final versions = await _geofences.allVersions();

    var transitions = 0;
    var visitCount = 0;
    var tripCount = 0;
    var rejected = 0;

    for (final vehicleId in targets) {
      // The whole retained window for this vehicle, not just the new fixes.
      //
      // A narrower window would be faster and wrong: dwell confirmation and
      // hysteresis both depend on the fixes *before* the one that arrived, so
      // starting mid-stream would invent a boundary that is not in the data.
      // The window is bounded by retention rather than by recency.
      final vehicleFixes = await _fixes.fixesFor(vehicleId, from: horizon);
      if (vehicleFixes.isEmpty) continue;

      final reduction = reduceGeofences(
        vehicleId: vehicleId,
        fixes: vehicleFixes,
        versions: versions,
      );
      final trips = reduceTrips(
        vehicleId: vehicleId,
        transitions: reduction.transitions,
      );

      await _writer.replaceDerived(
        vehicleId: vehicleId,
        from: horizon,
        visits: reduction.visits,
        trips: trips,
      );

      transitions += reduction.transitions.length;
      visitCount += reduction.visits.length;
      tripCount += trips.length;
      rejected += reduction.rejected.length;
    }

    return ReplayResult(
      vehiclesReplayed: targets.length,
      transitions: transitions,
      visits: visitCount,
      trips: tripCount,
      rejectedFixes: rejected,
    );
  }
}
