/// Trips built from confirmed transitions.
///
/// The brief's rules: a confirmed exit starts a trip, the next confirmed entry
/// completes it, and no confirmed entry leaves it IN PROGRESS. Plus the two it
/// leaves open — returning to the origin, and what happens when the entry that
/// should have closed a trip never arrives.
library;

import 'package:fleet_console/domain/entities/geofence.dart';
import 'package:fleet_console/domain/reducers/trip_reducer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime.utc(2026, 3, 1, 8);

  ConfirmedTransition exit(
    String geofenceId,
    Duration at, {
    bool inferred = false,
  }) => ConfirmedTransition(
    vehicleId: 'V1',
    geofenceId: geofenceId,
    versionId: '$geofenceId-v1',
    kind: TransitionKind.exit,
    crossedAt: t0.add(at),
    confirmedAt: t0.add(at + const Duration(minutes: 2)),
    inferredDuringGap: inferred,
  );

  ConfirmedTransition entry(
    String geofenceId,
    Duration at, {
    bool inferred = false,
  }) => ConfirmedTransition(
    vehicleId: 'V1',
    geofenceId: geofenceId,
    versionId: '$geofenceId-v1',
    kind: TransitionKind.entry,
    crossedAt: t0.add(at),
    confirmedAt: t0.add(at + const Duration(minutes: 2)),
    inferredDuringGap: inferred,
  );

  List<Trip> reduce(List<ConfirmedTransition> transitions) =>
      reduceTrips(vehicleId: 'V1', transitions: transitions);

  group("the brief's three rules", () {
    test('a confirmed exit starts a trip', () {
      final trips = reduce([exit('depot', Duration.zero)]);

      expect(trips, hasLength(1));
      expect(trips.single.status, TripStatus.inProgress);
      expect(trips.single.originGeofenceId, 'depot');
      expect(trips.single.startedAt, t0);
      expect(trips.single.endedAt, isNull);
    });

    test('the next confirmed entry completes it', () {
      final trips = reduce([
        exit('depot', Duration.zero),
        entry('site', const Duration(hours: 2)),
      ]);

      expect(trips, hasLength(1));
      final trip = trips.single;
      expect(trip.status, TripStatus.completed);
      expect(trip.originGeofenceId, 'depot');
      expect(trip.destinationGeofenceId, 'site');
      expect(trip.duration, const Duration(hours: 2));
    });

    test('no confirmed entry leaves it IN PROGRESS', () {
      final trips = reduce([exit('depot', Duration.zero)]);
      expect(trips.single.status, TripStatus.inProgress);
      expect(trips.single.destinationUnknown, isFalse);
    });
  });

  group('the cases the brief leaves open', () {
    test('returning to the origin is a valid trip, not deduped away', () {
      // A delivery run that comes home is still a trip.
      final trips = reduce([
        exit('depot', Duration.zero),
        entry('depot', const Duration(hours: 4)),
      ]);

      expect(trips, hasLength(1));
      expect(trips.single.status, TripStatus.completed);
      expect(trips.single.returnedToOrigin, isTrue);
      expect(trips.single.destinationGeofenceId, 'depot');
    });

    test('an exit while a trip is open closes it with an unknown destination',
        () {
      // The entry that should have closed the first trip was never confirmed,
      // almost always because it fell inside a reporting gap. Dropping the new
      // trip or pretending the old one is still running would both be worse.
      final trips = reduce([
        exit('depot', Duration.zero),
        exit('site', const Duration(hours: 3)),
      ]);

      expect(trips, hasLength(2));
      final first = trips.first;
      expect(first.status, TripStatus.completed);
      expect(first.destinationUnknown, isTrue);
      expect(first.destinationGeofenceId, isNull);
      expect(first.endedAt, t0.add(const Duration(hours: 3)));

      expect(trips.last.status, TripStatus.inProgress);
      expect(trips.last.originGeofenceId, 'site');
    });

    test('an entry with no trip open is ignored', () {
      // We simply were not watching when it left. Inventing a trip with a
      // fabricated start would be worse than recording nothing.
      expect(reduce([entry('depot', Duration.zero)]), isEmpty);
    });

    test('only one trip is ever active', () {
      final trips = reduce([
        exit('a', Duration.zero),
        exit('b', const Duration(hours: 1)),
        exit('c', const Duration(hours: 2)),
      ]);

      expect(trips, hasLength(3));
      expect(
        trips.where((t) => t.status == TripStatus.inProgress),
        hasLength(1),
      );
    });

    test('the inferred flag carries into the trip', () {
      final trips = reduce([
        exit('depot', Duration.zero, inferred: true),
        entry('site', const Duration(hours: 2)),
      ]);
      expect(trips.single.inferredDuringGap, isTrue);
    });

    test('an inferred entry also flags the trip', () {
      final trips = reduce([
        exit('depot', Duration.zero),
        entry('site', const Duration(hours: 2), inferred: true),
      ]);
      expect(trips.single.inferredDuringGap, isTrue);
    });
  });

  group('idempotence — the property replay depends on', () {
    test('reducing twice produces identical trips, ids included', () {
      final transitions = [
        exit('depot', Duration.zero),
        entry('site', const Duration(hours: 2)),
        exit('site', const Duration(hours: 3)),
      ];

      expect(reduce(transitions), reduce(transitions));
    });

    test('trip ids are derived, not generated', () {
      // A random uuid would make every replay produce a parallel set of
      // duplicate trips. This single property is what makes "late packets may
      // revise trip boundaries without producing duplicate trips" true.
      expect(tripIdFor('V1', t0), tripIdFor('V1', t0));
      expect(tripIdFor('V1', t0), isNot(tripIdFor('V2', t0)));
      expect(
        tripIdFor('V1', t0),
        isNot(tripIdFor('V1', t0.add(const Duration(seconds: 1)))),
      );
    });

    test('input order does not matter', () {
      final ordered = [
        exit('depot', Duration.zero),
        entry('site', const Duration(hours: 2)),
        exit('site', const Duration(hours: 3)),
        entry('depot', const Duration(hours: 5)),
      ];
      final shuffled = [ordered[3], ordered[1], ordered[0], ordered[2]];

      expect(reduce(shuffled), reduce(ordered));
    });

    test('a late transition revises a boundary without duplicating the trip',
        () {
      // First pass: we never saw the arrival, so the trip is still running.
      final before = reduce([exit('depot', Duration.zero)]);
      expect(before.single.status, TripStatus.inProgress);

      // The entry turns up late. Replaying the whole set closes the *same*
      // trip rather than creating a second one.
      final after = reduce([
        exit('depot', Duration.zero),
        entry('site', const Duration(hours: 2)),
      ]);

      expect(after, hasLength(1));
      expect(after.single.tripId, before.single.tripId);
      expect(after.single.status, TripStatus.completed);
    });

    test('an exit and an entry at the same instant order exit first', () {
      // You have to leave somewhere before you arrive somewhere else, so the
      // exit opens the trip and the entry then closes it. The result is a
      // zero-duration trip, which happens with adjacent fences where a single
      // fix confirms both crossings.
      //
      // Keeping it is deliberate. The duration is an artefact of how coarsely
      // we sampled, but "this truck moved from the depot to the site" is a
      // real fact, and dropping the trip would lose it.
      final trips = reduce([
        entry('site', const Duration(hours: 1)),
        exit('depot', const Duration(hours: 1)),
      ]);

      expect(trips, hasLength(1));
      expect(trips.single.originGeofenceId, 'depot');
      expect(trips.single.destinationGeofenceId, 'site');
      expect(trips.single.status, TripStatus.completed);
      expect(trips.single.duration, Duration.zero);
    });
  });

  group('degenerate input', () {
    test('no transitions means no trips', () {
      expect(reduce([]), isEmpty);
    });

    test('a long alternating chain stays consistent', () {
      final transitions = <ConfirmedTransition>[];
      for (var i = 0; i < 10; i++) {
        transitions
          ..add(exit('depot', Duration(hours: i * 4)))
          ..add(entry('site', Duration(hours: i * 4 + 2)));
      }

      final trips = reduce(transitions);
      expect(trips, hasLength(10));
      expect(trips.every((t) => t.status == TripStatus.completed), isTrue);
      expect(
        trips.map((t) => t.tripId).toSet(),
        hasLength(10),
        reason: 'ids must be unique across trips',
      );
    });
  });
}
