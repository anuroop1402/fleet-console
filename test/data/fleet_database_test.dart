/// Schema migration and on-disk durability.
///
/// The brief's §2 is not "use DuckDB", it is "kill the app and everything comes
/// back off disk". These tests close the database and reopen it from the same
/// file, which is the only way to test that claim — an in-memory database
/// cannot fail it.
library;

import 'package:fleet_console/data/duckdb/schema.dart';
import 'package:fleet_console/domain/entities/signal_kind.dart';
import 'package:fleet_console/domain/entities/telemetry_packet.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_database.dart';

void main() {
  final now = DateTime.utc(2026, 3, 1, 12);

  group('migrations', () {
    test('creates every table on a fresh database', () async {
      final h = await TestHarness.inMemory(now: now);
      addTearDown(h.dispose);

      final tables = (await h.rows(
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_schema = 'main' ORDER BY table_name",
      )).map((row) => row.first).toList();

      expect(tables, [
        'alerts',
        'latest_readings',
        'location_fixes',
        'rejected_packets',
        'schema_migrations',
        'signal_readings',
        'vehicles',
      ]);
    });

    test('records every applied version exactly once', () async {
      final h = await TestHarness.inMemory(now: now);
      addTearDown(h.dispose);

      // Asserted against migrations.length rather than a literal, so adding a
      // migration does not break this test — but applying one twice still does.
      expect(
        await h.count('SELECT COUNT(*) FROM schema_migrations'),
        migrations.length,
      );
      expect(
        (await h.rows('SELECT version FROM schema_migrations ORDER BY version'))
            .map((row) => row.first)
            .toList(),
        [for (var v = 1; v <= migrations.length; v++) v],
      );
    });

    test('reopening an existing database does not reapply migrations',
        () async {
      final first = await TestHarness.onDisk(now: now);
      final second = await first.reopen();
      addTearDown(second.dispose);

      expect(
        await second.count('SELECT COUNT(*) FROM schema_migrations'),
        migrations.length,
        reason: 'migrations must be applied exactly once',
      );
    });
  });

  group('durability — the local-first requirement', () {
    test('readings written before a close are there after reopening',
        () async {
      final first = await TestHarness.onDisk(now: now);
      await first.ingestor.ingest([
        packet(
          packetId: 'p1',
          eventTs: now.subtract(const Duration(minutes: 2)),
          signals: {SignalKind.soc: 63, SignalKind.speed: 41},
        ),
        packet(
          packetId: 'p2',
          vehicleId: 'V2',
          eventTs: now.subtract(const Duration(minutes: 1)),
          signals: {SignalKind.soc: 12},
          location: const GeoFix(
            latitude: 12.9716,
            longitude: 77.5946,
            accuracyMetres: 10,
          ),
        ),
      ]);
      await first.db.checkpoint();

      final reopened = await first.reopen();
      addTearDown(reopened.dispose);

      expect(await reopened.count('SELECT COUNT(*) FROM signal_readings'), 3);
      expect(await reopened.count('SELECT COUNT(*) FROM latest_readings'), 3);
      expect(
        await reopened.scalar(
          "SELECT value_num FROM latest_readings "
          "WHERE vehicle_id = 'V1' AND signal = 'soc'",
        ),
        63,
      );
    });

    test('survives without an explicit checkpoint — the WAL is replayed',
        () async {
      // Android kills apps without warning, so dispose() and CHECKPOINT are
      // best-effort. This asserts the database is still recoverable when the
      // only thing that ran was a committed transaction.
      final first = await TestHarness.onDisk(now: now);
      await first.ingestor.ingest([
        packet(packetId: 'p1', eventTs: now, signals: {SignalKind.soc: 25}),
      ]);

      final reopened = await first.reopen();
      addTearDown(reopened.dispose);

      expect(await reopened.count('SELECT COUNT(*) FROM signal_readings'), 1);
      expect(
        await reopened.scalar(
          "SELECT value_num FROM latest_readings WHERE signal = 'soc'",
        ),
        25,
      );
    });

    test('the event-time guard still holds across a restart', () async {
      final first = await TestHarness.onDisk(now: now);
      await first.ingestor.ingest([
        packet(
          packetId: 'fresh',
          eventTs: now.subtract(const Duration(minutes: 1)),
          signals: {SignalKind.soc: 40},
        ),
      ]);

      final reopened = await first.reopen();
      addTearDown(reopened.dispose);

      // A late packet arriving after the restart must still lose.
      await reopened.ingestor.ingest([
        packet(
          packetId: 'stale',
          eventTs: now.subtract(const Duration(hours: 1)),
          signals: {SignalKind.soc: 95},
        ),
      ]);

      expect(
        await reopened.scalar(
          "SELECT value_num FROM latest_readings WHERE signal = 'soc'",
        ),
        40,
        reason: 'the projection was rebuilt from disk, guard and all',
      );
    });

    test('the projection can be rebuilt from the log alone', () async {
      // latest_readings is a projection, not a second source of truth. If they
      // ever disagree, the log wins — so the log must be sufficient.
      final h = await TestHarness.onDisk(now: now);
      addTearDown(h.dispose);

      await h.ingestor.ingest([
        packet(
          packetId: 'a',
          eventTs: now.subtract(const Duration(minutes: 9)),
          signals: {SignalKind.soc: 70},
        ),
        packet(
          packetId: 'b',
          eventTs: now.subtract(const Duration(minutes: 1)),
          signals: {SignalKind.soc: 30},
        ),
      ]);

      final before = await h.rows(
        'SELECT vehicle_id, signal, event_ts, packet_id, value_num '
        'FROM latest_readings ORDER BY vehicle_id, signal',
      );

      await h.db.connection.execute('DELETE FROM latest_readings');
      await h.db.connection.execute('''
        INSERT INTO latest_readings
        SELECT vehicle_id, signal, event_ts, ingested_ts, packet_id, value_num
        FROM (
          SELECT *, ROW_NUMBER() OVER (
                      PARTITION BY vehicle_id, signal
                      ORDER BY event_ts DESC, ingested_ts DESC, packet_id DESC
                    ) AS rn
          FROM signal_readings
        ) WHERE rn = 1
      ''');

      final after = await h.rows(
        'SELECT vehicle_id, signal, event_ts, packet_id, value_num '
        'FROM latest_readings ORDER BY vehicle_id, signal',
      );

      expect(after, before);
    });
  });
}

