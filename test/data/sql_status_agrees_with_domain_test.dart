/// The status rule exists twice. This proves the two copies agree.
///
/// The brief requires the filter counts to be computed in SQL, and pulling 500
/// vehicles into Dart to classify them would defeat the projection that makes
/// the list fast. So the first-match-wins rule lives both in
/// `domain/rules/status_rules.dart` and in `data/duckdb/queries/fleet_queries.dart`.
///
/// Duplicated logic drifts. The mitigation is not discipline, it is this test:
/// every case is driven through *both* implementations and their answers are
/// compared. `statusOf` is the reference; the SQL has to match it.
library;

import 'package:fleet_console/data/repositories/duckdb_fleet_repository.dart';
import 'package:fleet_console/domain/entities/fleet_view.dart';
import 'package:fleet_console/domain/entities/signal_kind.dart';
import 'package:fleet_console/domain/entities/signal_reading.dart';
import 'package:fleet_console/domain/entities/telemetry_packet.dart';
import 'package:fleet_console/domain/entities/vehicle_status.dart';
import 'package:fleet_console/domain/rules/status_rules.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_database.dart';

/// One row of the agreement matrix.
final class _Case {
  const _Case(this.description, this.signals);

  final String description;

  /// Signal -> (value, age).
  final Map<SignalKind, (double, Duration)> signals;
}

void main() {
  late TestHarness h;
  late DuckDbFleetRepository repository;
  final now = DateTime.utc(2026, 3, 1, 12);

  const fresh = Duration(minutes: 1);
  const borderlineFresh = Duration(minutes: 10);
  const stale = Duration(minutes: 30);
  const veryOld = Duration(hours: 6);

  const cases = <_Case>[
    _Case('nothing reported', {}),
    _Case('moving', {
      SignalKind.speed: (45, fresh),
      SignalKind.ignition: (1, fresh),
    }),
    _Case('idle', {
      SignalKind.speed: (0, fresh),
      SignalKind.ignition: (1, fresh),
    }),
    _Case('stopped', {
      SignalKind.speed: (0, fresh),
      SignalKind.ignition: (0, fresh),
    }),
    _Case('moving beats a contradicting ignition-off', {
      SignalKind.speed: (45, fresh),
      SignalKind.ignition: (0, fresh),
    }),
    _Case('offline — everything is old', {
      SignalKind.speed: (45, veryOld),
      SignalKind.ignition: (1, veryOld),
    }),
    _Case('online via odometer only', {
      SignalKind.odometer: (120000, fresh),
    }),
    _Case('online but speed is stale', {
      SignalKind.odometer: (120000, fresh),
      SignalKind.speed: (55, stale),
    }),
    _Case('online but ignition is stale', {
      SignalKind.odometer: (120000, fresh),
      SignalKind.ignition: (0, stale),
    }),
    _Case('fresh zero speed, stale ignition', {
      SignalKind.speed: (0, fresh),
      SignalKind.ignition: (1, stale),
    }),
    _Case('exactly at the freshness boundary', {
      SignalKind.speed: (0, borderlineFresh),
      SignalKind.ignition: (1, borderlineFresh),
    }),
    _Case('exactly at the offline boundary', {
      SignalKind.odometer: (1, Duration(minutes: 10)),
    }),
    _Case('one second past the offline boundary', {
      SignalKind.odometer: (1, Duration(minutes: 10, seconds: 1)),
    }),
    _Case('ignition on but no speed at all', {
      SignalKind.ignition: (1, fresh),
    }),
    _Case('negative speed — a bad sensor, still not moving', {
      SignalKind.speed: (-3, fresh),
      SignalKind.ignition: (1, fresh),
    }),
  ];

  setUp(() async {
    h = await TestHarness.inMemory(now: now);
    repository = DuckDbFleetRepository(h.db);

    // One vehicle per case, so a single query covers the whole matrix.
    await repository.upsertVehicles([
      for (var i = 0; i < cases.length; i++)
        Vehicle(
          vehicleId: 'V$i',
          regNumber: 'KA01AB${i.toString().padLeft(4, '0')}',
          model: 'Truck',
        ),
    ]);

    final packets = <TelemetryPacket>[];
    for (var i = 0; i < cases.length; i++) {
      cases[i].signals.forEach((kind, spec) {
        packets.add(
          packet(
            packetId: 'p$i-${kind.wireName}',
            vehicleId: 'V$i',
            eventTs: now.subtract(spec.$2),
            signals: {kind: spec.$1},
          ),
        );
      });
    }
    if (packets.isNotEmpty) await h.ingestor.ingest(packets);
  });

  tearDown(() async => h.dispose());

  VehicleSnapshot snapshotFor(int index) => VehicleSnapshot(
    vehicleId: 'V$index',
    readings: {
      for (final entry in cases[index].signals.entries)
        entry.key: SignalReading(
          kind: entry.key,
          value: entry.value.$1,
          eventTs: now.subtract(entry.value.$2),
        ),
    },
  );

  test('SQL and statusOf agree on every case in the matrix', () async {
    final rows = await repository.fleetList(now: now);
    final byId = {for (final row in rows) row.vehicleId: row.status};

    final disagreements = <String>[];
    for (var i = 0; i < cases.length; i++) {
      final fromDart = statusOf(snapshotFor(i), now);
      final fromSql = byId['V$i'];
      if (fromDart != fromSql) {
        disagreements.add(
          '${cases[i].description}: Dart said $fromDart, SQL said $fromSql',
        );
      }
    }

    expect(
      disagreements,
      isEmpty,
      reason:
          'The SQL status expression has drifted from statusOf.\n'
          '${disagreements.join('\n')}',
    );
  });

  test('the matrix actually covers every status', () async {
    // Guards against the agreement test passing vacuously because the cases
    // all happen to produce the same answer.
    final produced = {
      for (var i = 0; i < cases.length; i++) statusOf(snapshotFor(i), now),
    };
    expect(produced, containsAll(VehicleStatus.values));
  });

  test('filter counts agree with the filtered lists', () async {
    final counts = await repository.statusCounts(now: now);

    for (final status in VehicleStatus.values) {
      final filtered = await repository.fleetList(now: now, status: status);
      expect(
        filtered.length,
        counts[status] ?? 0,
        reason: 'the $status chip must match what tapping it shows',
      );
      expect(
        filtered.every((row) => row.status == status),
        isTrue,
        reason: 'the $status filter returned a row of another status',
      );
    }
  });

  test('the counts sum to the fleet size', () async {
    final counts = await repository.statusCounts(now: now);
    final total = counts.values.fold(0, (sum, n) => sum + n);
    expect(total, cases.length);
    expect(total, await repository.vehicleCount());
  });
}
