/// The deterministic geofence strategy, one group per failure mode the brief
/// names: duplicates, late packets, GPS jitter, inaccurate readings, overlaps,
/// missing intervals, and geofence edits.
///
/// No database anywhere. That is the point of the reducer being pure — each
/// awkward case is a hand-built fixture rather than a database scenario.
library;

import 'package:fleet_console/core/constants.dart';
import 'package:fleet_console/domain/entities/geofence.dart';
import 'package:fleet_console/domain/reducers/geofence_reducer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime.utc(2026, 3, 1, 8);

  // A depot at a round location, 200 m radius.
  const depotLat = 12.9716;
  const depotLon = 77.5946;

  GeofenceVersion depot({
    String geofenceId = 'depot',
    String versionId = 'depot-v1',
    double radius = 200,
    double lat = depotLat,
    double lon = depotLon,
    DateTime? from,
    DateTime? to,
    bool active = true,
  }) => GeofenceVersion(
    geofenceId: geofenceId,
    versionId: versionId,
    name: 'Depot',
    latitude: lat,
    longitude: lon,
    radiusMetres: radius,
    validFrom: from ?? DateTime.utc(2020),
    validTo: to,
    isActive: active,
  );

  /// Metres north of the depot centre, converted to a latitude offset.
  double latAt(double metresNorth) => depotLat + metresNorth / 111320.0;

  var packetSeq = 0;
  LocationFix fixAt({
    required double metresFromCentre,
    required Duration after,
    double accuracy = 5,
    DateTime? ingestedAt,
    String? packetId,
  }) {
    packetSeq++;
    final eventTs = t0.add(after);
    return LocationFix(
      vehicleId: 'V1',
      eventTs: eventTs,
      ingestedTs: ingestedAt ?? eventTs,
      packetId: packetId ?? 'p${packetSeq.toString().padLeft(3, '0')}',
      latitude: latAt(metresFromCentre),
      longitude: depotLon,
      accuracyMetres: accuracy,
    );
  }

  setUp(() => packetSeq = 0);

  GeofenceReduction reduce(
    List<LocationFix> fixes, {
    List<GeofenceVersion>? versions,
  }) => reduceGeofences(
    vehicleId: 'V1',
    fixes: fixes,
    versions: versions ?? [depot()],
  );

  group('the basic crossing', () {
    test('a confirmed exit is produced after enough fixes and dwell', () {
      final reduction = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        fixAt(metresFromCentre: 50, after: const Duration(minutes: 1)),
        // Now outside, well past the buffer.
        fixAt(metresFromCentre: 400, after: const Duration(minutes: 5)),
        fixAt(metresFromCentre: 500, after: const Duration(minutes: 7)),
      ]);

      expect(reduction.transitions, hasLength(1));
      final exit = reduction.transitions.single;
      expect(exit.kind, TransitionKind.exit);
      expect(
        exit.crossedAt,
        t0.add(const Duration(minutes: 5)),
        reason: 'the crossing is the first fix of the run, not the confirming one',
      );
      expect(exit.confirmedAt, t0.add(const Duration(minutes: 7)));
      expect(exit.inferredDuringGap, isFalse);
    });

    test('a single outside fix confirms nothing', () {
      // One fix is an opinion, not a crossing.
      final reduction = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        fixAt(metresFromCentre: 400, after: const Duration(minutes: 2)),
      ]);
      expect(reduction.transitions, isEmpty);
    });

    test('two fixes inside the dwell window confirm nothing', () {
      // Enough fixes, not enough time — a truck at the gate for ten seconds
      // has not left.
      final reduction = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        fixAt(metresFromCentre: 400, after: const Duration(minutes: 2)),
        fixAt(
          metresFromCentre: 420,
          after: const Duration(minutes: 2, seconds: 10),
        ),
      ]);
      expect(reduction.transitions, isEmpty);
    });

    test('an exit then a re-entry produces both, and closes the visit', () {
      final reduction = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        fixAt(metresFromCentre: 400, after: const Duration(minutes: 5)),
        fixAt(metresFromCentre: 500, after: const Duration(minutes: 7)),
        fixAt(metresFromCentre: 20, after: const Duration(minutes: 40)),
        fixAt(metresFromCentre: 10, after: const Duration(minutes: 42)),
      ]);

      expect(
        reduction.transitions.map((t) => t.kind).toList(),
        [TransitionKind.exit, TransitionKind.entry],
      );
      // The visit that was open at the start closes on the exit; the re-entry
      // opens a new one that is still open at the end of the log.
      expect(reduction.visits.where((v) => v.isOpen), hasLength(1));
    });
  });

  group('duplicates', () {
    test('a repeated packet creates nothing twice', () {
      final fix = fixAt(metresFromCentre: 400, after: const Duration(minutes: 5));
      final reduction = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        fix,
        fix,
        fixAt(metresFromCentre: 500, after: const Duration(minutes: 7)),
      ]);

      expect(reduction.transitions, hasLength(1));
      expect(
        reduction.rejected.where((r) => r.reason == FixRejection.duplicate),
        hasLength(1),
      );
    });

    test('reducing the same log twice gives an identical answer', () {
      final fixes = [
        fixAt(metresFromCentre: 0, after: Duration.zero),
        fixAt(metresFromCentre: 400, after: const Duration(minutes: 5)),
        fixAt(metresFromCentre: 500, after: const Duration(minutes: 7)),
      ];

      expect(
        reduce(fixes).transitions,
        reduce(fixes).transitions,
        reason: 'idempotence is what makes replay safe',
      );
    });

    test('two packets claiming the same instant resolve deterministically', () {
      final at = t0.add(const Duration(minutes: 5));
      LocationFix contender(String id, double metres) => LocationFix(
        vehicleId: 'V1',
        eventTs: at,
        ingestedTs: at,
        packetId: id,
        latitude: latAt(metres),
        longitude: depotLon,
        accuracyMetres: 5,
      );

      final forwards = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        contender('aaa', 400),
        contender('zzz', 0),
        fixAt(metresFromCentre: 500, after: const Duration(minutes: 7)),
      ]);
      final backwards = reduce([
        fixAt(metresFromCentre: 500, after: const Duration(minutes: 7)),
        contender('zzz', 0),
        contender('aaa', 400),
        fixAt(metresFromCentre: 0, after: Duration.zero),
      ]);

      expect(forwards.transitions, backwards.transitions);
    });
  });

  group('late packets', () {
    test('input order does not change the result', () {
      // The whole late-packet strategy rests on this: if order of arrival
      // changed the answer, replay could not fix anything.
      final inOrder = [
        fixAt(metresFromCentre: 0, after: Duration.zero),
        fixAt(metresFromCentre: 400, after: const Duration(minutes: 5)),
        fixAt(metresFromCentre: 500, after: const Duration(minutes: 7)),
        fixAt(metresFromCentre: 600, after: const Duration(minutes: 9)),
      ];
      final shuffled = [inOrder[2], inOrder[0], inOrder[3], inOrder[1]];

      expect(reduce(shuffled).transitions, reduce(inOrder).transitions);
    });

    test('a late fix arriving after the fact revises the crossing time', () {
      // Without the earlier fix, the run starts at minute 7.
      final without = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        fixAt(metresFromCentre: 500, after: const Duration(minutes: 7)),
        fixAt(metresFromCentre: 600, after: const Duration(minutes: 9)),
      ]);
      expect(
        without.transitions.single.crossedAt,
        t0.add(const Duration(minutes: 7)),
      );

      // The missing minute-5 fix turns up late. Replay moves the crossing
      // earlier — a revision, not a second transition.
      final withLate = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        fixAt(metresFromCentre: 500, after: const Duration(minutes: 7)),
        fixAt(metresFromCentre: 600, after: const Duration(minutes: 9)),
        LocationFix(
          vehicleId: 'V1',
          eventTs: t0.add(const Duration(minutes: 5)),
          ingestedTs: t0.add(const Duration(minutes: 20)),
          packetId: 'late',
          latitude: latAt(400),
          longitude: depotLon,
          accuracyMetres: 5,
        ),
      ]);

      expect(withLate.transitions, hasLength(1));
      expect(
        withLate.transitions.single.crossedAt,
        t0.add(const Duration(minutes: 5)),
      );
    });
  });

  group('GPS jitter', () {
    test('wobbling across the boundary produces no transitions', () {
      // A truck parked on the fence line. Without hysteresis this is an
      // endless stream of entries and exits, and therefore of trips.
      final fixes = <LocationFix>[
        fixAt(metresFromCentre: 0, after: Duration.zero),
      ];
      for (var i = 1; i <= 20; i++) {
        fixes.add(
          fixAt(
            metresFromCentre: i.isEven ? 198 : 202,
            after: Duration(minutes: i * 2),
          ),
        );
      }

      expect(reduce(fixes).transitions, isEmpty);
    });

    test('the band is sticky — an ambiguous fix does not break a run', () {
      final reduction = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        fixAt(metresFromCentre: 400, after: const Duration(minutes: 5)),
        // On the line: no opinion. Must not reset the run building above.
        fixAt(metresFromCentre: 200, after: const Duration(minutes: 6)),
        fixAt(metresFromCentre: 450, after: const Duration(minutes: 7)),
      ]);

      expect(reduction.transitions, hasLength(1));
      expect(
        reduction.transitions.single.crossedAt,
        t0.add(const Duration(minutes: 5)),
      );
    });

    test('a genuine departure still registers', () {
      // Hysteresis must suppress noise without suppressing signal.
      final reduction = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        fixAt(metresFromCentre: 1000, after: const Duration(minutes: 5)),
        fixAt(metresFromCentre: 2000, after: const Duration(minutes: 8)),
      ]);
      expect(reduction.transitions, hasLength(1));
    });
  });

  group('inaccurate readings', () {
    test('a wildly inaccurate fix is dropped', () {
      final reduction = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        fixAt(
          metresFromCentre: 400,
          after: const Duration(minutes: 5),
          accuracy: 900,
        ),
        fixAt(metresFromCentre: 500, after: const Duration(minutes: 7)),
      ]);

      expect(
        reduction.rejected.where((r) => r.reason == FixRejection.tooInaccurate),
        hasLength(1),
      );
      expect(
        reduction.transitions,
        isEmpty,
        reason: 'only one usable outside fix remains, which cannot confirm',
      );
    });

    test('a merely sloppy fix widens the band instead of being dropped', () {
      // 120 m accuracy on a 200 m fence: usable, but it has to be further out
      // before it counts as having left.
      final justOutside = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        fixAt(
          metresFromCentre: 260,
          after: const Duration(minutes: 5),
          accuracy: 120,
        ),
        fixAt(
          metresFromCentre: 270,
          after: const Duration(minutes: 7),
          accuracy: 120,
        ),
      ]);
      expect(
        justOutside.transitions,
        isEmpty,
        reason: '260 m is inside 200 + 120, so it carries no opinion',
      );

      final clearlyOutside = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        fixAt(
          metresFromCentre: 400,
          after: const Duration(minutes: 5),
          accuracy: 120,
        ),
        fixAt(
          metresFromCentre: 420,
          after: const Duration(minutes: 7),
          accuracy: 120,
        ),
      ]);
      expect(clearlyOutside.transitions, hasLength(1));
    });

    test('a teleport is rejected, not treated as a fast truck', () {
      final reduction = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        // 500 km away, one minute later.
        LocationFix(
          vehicleId: 'V1',
          eventTs: t0.add(const Duration(minutes: 1)),
          ingestedTs: t0.add(const Duration(minutes: 1)),
          packetId: 'teleport',
          latitude: 19.0760,
          longitude: 72.8777,
          accuracyMetres: 5,
        ),
        fixAt(metresFromCentre: 10, after: const Duration(minutes: 2)),
      ]);

      expect(
        reduction.rejected.where((r) => r.reason == FixRejection.teleport),
        hasLength(1),
      );
      expect(reduction.transitions, isEmpty);
    });
  });

  group('missing intervals', () {
    test('a crossing across a long gap is flagged and stamped late', () {
      final reduction = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        // Three hours of silence, then it is plainly elsewhere.
        fixAt(metresFromCentre: 5000, after: const Duration(hours: 3)),
        fixAt(
          metresFromCentre: 5200,
          after: const Duration(hours: 3, minutes: 5),
        ),
      ]);

      expect(reduction.transitions, hasLength(1));
      final exit = reduction.transitions.single;
      expect(
        exit.inferredDuringGap,
        isTrue,
        reason: 'we did not see it leave; we inferred it',
      );
      expect(
        exit.crossedAt,
        t0.add(const Duration(hours: 3)),
        reason: 'stamped at the first post-gap fix, not fabricated mid-gap',
      );
    });

    test('a gap resets a run that was building', () {
      final reduction = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        fixAt(metresFromCentre: 400, after: const Duration(minutes: 5)),
        // Gap. The half-built run cannot survive it — we do not know what
        // happened in between.
        fixAt(metresFromCentre: 450, after: const Duration(hours: 4)),
      ]);

      expect(reduction.transitions, isEmpty);
    });

    test('a gap shorter than the limit does not flag anything', () {
      final reduction = reduce([
        fixAt(metresFromCentre: 0, after: Duration.zero),
        fixAt(metresFromCentre: 400, after: const Duration(minutes: 20)),
        fixAt(metresFromCentre: 450, after: const Duration(minutes: 25)),
      ]);

      expect(reduction.transitions, hasLength(1));
      expect(reduction.transitions.single.inferredDuringGap, isFalse);
    });
  });

  group('geofence edits', () {
    test('history is judged against the version live at the fix time', () {
      // The depot was small until 09:00, then enlarged. A fix at 08:30 that is
      // outside the small fence must read as outside, even though the current
      // definition would contain it.
      final small = depot(
        versionId: 'v1',
        radius: 100,
        to: t0.add(const Duration(hours: 1)),
      );
      final large = depot(
        versionId: 'v2',
        radius: 2000,
        from: t0.add(const Duration(hours: 1)),
      );

      final reduction = reduce(
        [
          fixAt(metresFromCentre: 0, after: Duration.zero),
          fixAt(metresFromCentre: 500, after: const Duration(minutes: 5)),
          fixAt(metresFromCentre: 520, after: const Duration(minutes: 8)),
        ],
        versions: [small, large],
      );

      expect(reduction.transitions, hasLength(1));
      expect(
        reduction.transitions.single.versionId,
        'v1',
        reason: 'the trip records the fence as it was at the time',
      );
    });

    test('a deactivated fence generates no new transitions', () {
      final reduction = reduce(
        [
          fixAt(metresFromCentre: 0, after: Duration.zero),
          fixAt(metresFromCentre: 400, after: const Duration(minutes: 5)),
          fixAt(metresFromCentre: 500, after: const Duration(minutes: 8)),
        ],
        versions: [depot(active: false)],
      );

      expect(reduction.transitions, isEmpty);
    });

    test('a fence created after the fact does not retro-fire', () {
      final reduction = reduce(
        [
          fixAt(metresFromCentre: 0, after: Duration.zero),
          fixAt(metresFromCentre: 400, after: const Duration(minutes: 5)),
          fixAt(metresFromCentre: 500, after: const Duration(minutes: 8)),
        ],
        versions: [depot(from: t0.add(const Duration(days: 1)))],
      );

      expect(reduction.transitions, isEmpty);
    });
  });

  group('overlaps', () {
    final depotVersion = depot(geofenceId: 'depot', radius: 500);
    final bay = depot(geofenceId: 'bay', versionId: 'bay-v1', radius: 60);

    test('both fences produce their own transitions', () {
      // Being inside a bay inside a depot is not a conflict — both are true.
      final reduction = reduce(
        [
          fixAt(metresFromCentre: 0, after: Duration.zero),
          fixAt(metresFromCentre: 2000, after: const Duration(minutes: 5)),
          fixAt(metresFromCentre: 2100, after: const Duration(minutes: 8)),
        ],
        versions: [depotVersion, bay],
      );

      expect(
        reduction.transitions.map((t) => t.geofenceId).toSet(),
        {'depot', 'bay'},
      );
    });

    test('the displayed current fence is the most specific one', () {
      expect(currentGeofenceFor([depotVersion, bay])!.geofenceId, 'bay');
      expect(currentGeofenceFor([bay, depotVersion])!.geofenceId, 'bay');
    });

    test('equal radii break the tie by id, deterministically', () {
      final a = depot(geofenceId: 'aaa', radius: 100);
      final b = depot(geofenceId: 'bbb', radius: 100);
      expect(currentGeofenceFor([b, a])!.geofenceId, 'aaa');
      expect(currentGeofenceFor([a, b])!.geofenceId, 'aaa');
    });

    test('no containing fence means no current fence', () {
      expect(currentGeofenceFor([]), isNull);
    });

    test('containingFences ignores hysteresis', () {
      // A snapshot question, not a transition question. Debouncing a label the
      // user is looking at right now would make it lag reality for no gain.
      final onTheLine = fixAt(
        metresFromCentre: 195,
        after: Duration.zero,
      );
      expect(containingFences(onTheLine, [depot()]), hasLength(1));
    });
  });

  group('degenerate input', () {
    test('no fixes reduces to nothing', () {
      expect(reduce([]).transitions, isEmpty);
      expect(reduce([]).visits, isEmpty);
    });

    test('no geofences reduces to nothing but still accepts fixes', () {
      final reduction = reduce(
        [
          fixAt(metresFromCentre: 0, after: Duration.zero),
          fixAt(metresFromCentre: 900, after: const Duration(minutes: 5)),
        ],
        versions: [],
      );
      expect(reduction.transitions, isEmpty);
      expect(reduction.acceptedFixCount, 2);
    });

    test('the confirmation thresholds are the documented ones', () {
      // Guards against a silent tuning change: these numbers are quoted in
      // docs/01 and defended in review.
      expect(GeofencePolicy.confirmationFixes, 2);
      expect(GeofencePolicy.confirmationDwell, const Duration(seconds: 60));
      expect(GeofencePolicy.maxReportingGap, const Duration(minutes: 30));
      expect(GeofencePolicy.minHysteresisMetres, 15);
      expect(GeofencePolicy.maxPlausibleSpeedKmh, 200);
    });
  });
}
