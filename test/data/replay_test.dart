/// Geofence versioning and trip replay, end to end through DuckDB.
///
/// The reducers are proven pure in `test/domain/`. These tests prove the
/// property that actually matters in production: replaying the log against the
/// real database is *idempotent*, so a late packet can be applied by
/// recomputation without duplicating or stranding anything.
library;

import 'package:fleet_console/data/repositories/duckdb_geofence_repository.dart';
import 'package:fleet_console/domain/entities/geofence.dart';
import 'package:fleet_console/domain/entities/telemetry_packet.dart';
import 'package:fleet_console/domain/usecases/replay_trips.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_database.dart';

void main() {
  // The window has to sit inside the 30-day raw-fix retention, or the fixes
  // would be rejected at ingest and there would be nothing to replay.
  final t0 = DateTime.utc(2026, 3, 1, 8);
  final now = t0.add(const Duration(hours: 12));

  const depotLat = 12.9716;
  const depotLon = 77.5946;
  const siteLat = 13.0827;
  const siteLon = 77.5946;

  late TestHarness h;
  late DuckDbGeofenceRepository repository;
  late ReplayTrips replay;

  setUp(() async {
    h = await TestHarness.inMemory(now: now);
    repository = DuckDbGeofenceRepository(h.db);
    replay = ReplayTrips(
      fixes: repository,
      geofences: repository,
      writer: repository,
      clock: h.clock,
    );
  });

  tearDown(() async => h.dispose());

  Future<GeofenceVersion> makeFence(
    String name,
    double lat,
    double lon,
    double radius,
  ) => repository.create(
    name: name,
    latitude: lat,
    longitude: lon,
    radiusMetres: radius,
    // Valid from well before any fix, so history is covered.
    at: t0.subtract(const Duration(days: 1)),
  );

  /// Ingests a location fix through the real pipeline.
  Future<void> reportAt({
    required double lat,
    required double lon,
    required Duration after,
    double accuracy = 5,
    Duration? arrivedAfter,
    String? packetId,
  }) async {
    final eventTs = t0.add(after);
    await h.ingestor.ingest([
      packet(
        packetId: packetId ?? 'p${eventTs.microsecondsSinceEpoch}',
        eventTs: eventTs,
        location: GeoFix(
          latitude: lat,
          longitude: lon,
          accuracyMetres: accuracy,
        ),
      ),
    ]);
  }

  /// A depot -> site run: two fixes at the depot, then two at the site.
  Future<void> reportDepotToSiteRun() async {
    await reportAt(lat: depotLat, lon: depotLon, after: Duration.zero);
    await reportAt(
      lat: depotLat,
      lon: depotLon,
      after: const Duration(minutes: 2),
    );
    await reportAt(
      lat: siteLat,
      lon: siteLon,
      after: const Duration(hours: 1),
    );
    await reportAt(
      lat: siteLat,
      lon: siteLon,
      after: const Duration(hours: 1, minutes: 5),
    );
  }

  group('geofence versioning', () {
    test('create makes a fence with one open version', () async {
      await makeFence('Depot', depotLat, depotLon, 300);

      final current = await repository.currentVersions();
      expect(current, hasLength(1));
      expect(current.single.name, 'Depot');
      expect(current.single.validTo, isNull);
    });

    test('edit closes the old version and opens a new one', () async {
      final first = await makeFence('Depot', depotLat, depotLon, 300);

      final second = await repository.edit(
        geofenceId: first.geofenceId,
        name: 'Depot (enlarged)',
        latitude: depotLat,
        longitude: depotLon,
        radiusMetres: 800,
        at: t0.add(const Duration(hours: 6)),
      );

      final all = await repository.allVersions();
      expect(all, hasLength(2), reason: 'history is kept, not overwritten');

      final closed = all.firstWhere((v) => v.versionId == first.versionId);
      expect(closed.validTo, t0.add(const Duration(hours: 6)));
      expect(closed.radiusMetres, 300, reason: 'the old shape is preserved');

      expect(second.radiusMetres, 800);
      expect(await repository.currentVersions(), hasLength(1));
    });

    test('deactivate closes the version but keeps it for history', () async {
      final fence = await makeFence('Depot', depotLat, depotLon, 300);
      await repository.deactivate(
        geofenceId: fence.geofenceId,
        at: t0.add(const Duration(hours: 6)),
      );

      expect(await repository.currentVersions(), isEmpty);
      expect(
        await repository.allVersions(),
        hasLength(1),
        reason: 'the brief asks for deactivated fences to be retained',
      );
    });

    test('editing does not rewrite history that already happened', () async {
      // The whole reason for SCD-2. A fix at the site is outside a 300 m depot
      // and inside an 800 m one; enlarging the fence later must not change
      // what the earlier trip meant.
      final depot = await makeFence('Depot', depotLat, depotLon, 300);
      await makeFence('Site', siteLat, siteLon, 300);
      await reportDepotToSiteRun();
      await replay(since: t0.subtract(const Duration(days: 1)));

      final before = await repository.tripsFor('V1');
      expect(before, hasLength(1));

      // Enlarge the depot *after* the trip happened.
      await repository.edit(
        geofenceId: depot.geofenceId,
        name: 'Depot',
        latitude: depotLat,
        longitude: depotLon,
        radiusMetres: 40000,
        at: now,
      );
      await replay(since: t0.subtract(const Duration(days: 1)));

      final after = await repository.tripsFor('V1');
      expect(
        after.map((t) => t.tripId).toList(),
        before.map((t) => t.tripId).toList(),
        reason: 'past trips are judged against the fence as it was',
      );
    });
  });

  group('trips from real fixes', () {
    setUp(() async {
      await makeFence('Depot', depotLat, depotLon, 300);
      await makeFence('Site', siteLat, siteLon, 300);
    });

    test('a depot to site run produces one completed trip', () async {
      await reportDepotToSiteRun();
      final result = await replay(since: t0.subtract(const Duration(days: 1)));

      expect(result.vehiclesReplayed, 1);
      final trips = await repository.tripsFor('V1');
      expect(trips, hasLength(1));
      expect(trips.single.status, TripStatus.completed);
      expect(trips.single.destinationUnknown, isFalse);
    });

    test('leaving with no arrival stays IN PROGRESS', () async {
      await reportAt(lat: depotLat, lon: depotLon, after: Duration.zero);
      await reportAt(
        lat: depotLat,
        lon: depotLon,
        after: const Duration(minutes: 2),
      );
      // Somewhere between the two fences, so no entry is confirmed.
      await reportAt(lat: 13.02, lon: depotLon, after: const Duration(hours: 1));
      await reportAt(
        lat: 13.02,
        lon: depotLon,
        after: const Duration(hours: 1, minutes: 5),
      );

      await replay(since: t0.subtract(const Duration(days: 1)));

      final trips = await repository.tripsFor('V1');
      expect(trips, hasLength(1));
      expect(trips.single.status, TripStatus.inProgress);
      expect(trips.single.endedAt, isNull);
    });

    test('visits record the stay and the vehicle count is live', () async {
      await reportDepotToSiteRun();
      await replay(since: t0.subtract(const Duration(days: 1)));

      final counts = await repository.vehicleCountsByGeofence();
      final current = await repository.currentGeofenceByVehicle();

      // The truck is at the site now, so only the site has an open visit.
      expect(counts.values.fold(0, (a, b) => a + b), 1);
      expect(current['V1'], isNotNull);
    });
  });

  group('replay is idempotent — the property everything rests on', () {
    setUp(() async {
      await makeFence('Depot', depotLat, depotLon, 300);
      await makeFence('Site', siteLat, siteLon, 300);
    });

    test('replaying twice leaves exactly the same rows', () async {
      await reportDepotToSiteRun();
      await replay(since: t0.subtract(const Duration(days: 1)));
      final first = await repository.tripsFor('V1');
      final firstVisits = await repository.visitsFor('V1');

      await replay(since: t0.subtract(const Duration(days: 1)));

      expect(await repository.tripsFor('V1'), first);
      expect(await repository.visitsFor('V1'), firstVisits);
    });

    test('replaying five times does not accumulate trips', () async {
      await reportDepotToSiteRun();
      for (var i = 0; i < 5; i++) {
        await replay(since: t0.subtract(const Duration(days: 1)));
      }
      expect(await repository.tripsFor('V1'), hasLength(1));
    });

    test('a duplicate packet creates nothing twice', () async {
      await reportDepotToSiteRun();
      // The same fix delivered again, byte for byte.
      await reportAt(
        lat: siteLat,
        lon: siteLon,
        after: const Duration(hours: 1),
        packetId: 'p${t0.add(const Duration(hours: 1)).microsecondsSinceEpoch}',
      );
      await replay(since: t0.subtract(const Duration(days: 1)));

      expect(await repository.tripsFor('V1'), hasLength(1));
    });

    test('a late packet revises the boundary without duplicating the trip',
        () async {
      // Leaves the depot and is seen en route, but the arrival at the site
      // never came, so the trip is still running.
      await reportAt(lat: depotLat, lon: depotLon, after: Duration.zero);
      await reportAt(
        lat: depotLat,
        lon: depotLon,
        after: const Duration(minutes: 2),
      );
      // Between the two fences: enough to confirm the depot exit, not enough
      // to enter anything.
      await reportAt(lat: 13.02, lon: depotLon, after: const Duration(hours: 1));
      await reportAt(
        lat: 13.02,
        lon: depotLon,
        after: const Duration(hours: 1, minutes: 5),
      );
      await replay(since: t0.subtract(const Duration(days: 1)));

      final before = await repository.tripsFor('V1');
      expect(before, hasLength(1));
      expect(before.single.status, TripStatus.inProgress);

      // The two site fixes turn up late, confirming the arrival after the
      // fact. Replay must fold them into the existing trip.
      await reportAt(
        lat: siteLat,
        lon: siteLon,
        after: const Duration(hours: 1, minutes: 30),
        packetId: 'arrived-late-1',
      );
      await reportAt(
        lat: siteLat,
        lon: siteLon,
        after: const Duration(hours: 1, minutes: 35),
        packetId: 'arrived-late-2',
      );
      await replay(since: t0.subtract(const Duration(days: 1)));

      final after = await repository.tripsFor('V1');
      expect(after, hasLength(1), reason: 'revised, not duplicated');
      expect(after.single.status, TripStatus.completed);
      expect(
        after.single.tripId,
        before.single.tripId,
        reason: 'the derived id is what makes revision possible',
      );
    });

    test('a replay that produces fewer rows removes the stale ones', () async {
      // Delete-then-insert exists for exactly this. An upsert would strand the
      // trip that no longer has any basis in the log.
      await reportDepotToSiteRun();
      await replay(since: t0.subtract(const Duration(days: 1)));
      expect(await repository.tripsFor('V1'), hasLength(1));

      // Deactivating both fences means no transitions can be derived at all.
      for (final version in await repository.currentVersions()) {
        await repository.deactivate(
          geofenceId: version.geofenceId,
          at: t0.subtract(const Duration(days: 2)),
        );
      }
      await replay(since: t0.subtract(const Duration(days: 1)));

      expect(
        await repository.tripsFor('V1'),
        isEmpty,
        reason: 'derived rows with no basis in the log must not survive',
      );
    });
  });

  group('durability', () {
    test('trips survive closing and reopening the database', () async {
      final onDisk = await TestHarness.onDisk(now: now);
      final repo = DuckDbGeofenceRepository(onDisk.db);
      final replayer = ReplayTrips(
        fixes: repo,
        geofences: repo,
        writer: repo,
        clock: onDisk.clock,
      );

      await repo.create(
        name: 'Depot',
        latitude: depotLat,
        longitude: depotLon,
        radiusMetres: 300,
        at: t0.subtract(const Duration(days: 1)),
      );
      await repo.create(
        name: 'Site',
        latitude: siteLat,
        longitude: siteLon,
        radiusMetres: 300,
        at: t0.subtract(const Duration(days: 1)),
      );

      for (final spec in [
        (depotLat, depotLon, Duration.zero),
        (depotLat, depotLon, const Duration(minutes: 2)),
        (siteLat, siteLon, const Duration(hours: 1)),
        (siteLat, siteLon, const Duration(hours: 1, minutes: 5)),
      ]) {
        final eventTs = t0.add(spec.$3);
        await onDisk.ingestor.ingest([
          packet(
            packetId: 'p${eventTs.microsecondsSinceEpoch}',
            eventTs: eventTs,
            location: GeoFix(
              latitude: spec.$1,
              longitude: spec.$2,
              accuracyMetres: 5,
            ),
          ),
        ]);
      }
      await replayer(since: t0.subtract(const Duration(days: 1)));
      await onDisk.db.checkpoint();

      final reopened = await onDisk.reopen();
      addTearDown(reopened.dispose);
      final reopenedRepo = DuckDbGeofenceRepository(reopened.db);

      expect(await reopenedRepo.tripsFor('V1'), hasLength(1));
      expect(
        await reopenedRepo.allVersions(),
        hasLength(2),
        reason: 'fence definitions come back off disk too',
      );
    });
  });
}
