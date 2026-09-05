/// Helpers for tests that need a real DuckDB database.
///
/// These are integration tests against the actual engine, not mocks. The whole
/// point of the ingest layer is that its SQL is correct — `ON CONFLICT ... WHERE`,
/// window-function tie-breaks and zone-map-friendly anti-joins are exactly the
/// things a mock would happily lie about.
library;

import 'dart:io';

import 'package:fleet_console/core/clock.dart';
import 'package:fleet_console/data/duckdb/fleet_database.dart';
import 'package:fleet_console/data/ingest/telemetry_ingestor.dart';
import 'package:fleet_console/domain/entities/signal_kind.dart';
import 'package:fleet_console/domain/entities/telemetry_packet.dart';

import 'duckdb_test_env.dart';

/// A throwaway database plus the pieces most tests need.
final class TestHarness {
  TestHarness._(this.db, this.clock, this.ingestor, this._tempDir);

  final FleetDatabase db;
  final FixedClock clock;
  final TelemetryIngestor ingestor;
  final Directory? _tempDir;

  /// An in-memory database. Fast; use this unless the test is about durability.
  static Future<TestHarness> inMemory({DateTime? now}) =>
      _create(':memory:', now, null);

  /// A file-backed database in a temp directory.
  ///
  /// Use for anything that has to survive a close and reopen — the brief's
  /// local-first requirement is about disk, and an in-memory database cannot
  /// prove it.
  static Future<TestHarness> onDisk({DateTime? now}) async {
    final dir = await Directory.systemTemp.createTemp('fleet_console_test');
    return _create('${dir.path}/fleet.duckdb', now, dir);
  }

  static Future<TestHarness> _create(
    String path,
    DateTime? now,
    Directory? tempDir,
  ) async {
    configureDuckDbForTests();
    final clock = FixedClock(now ?? DateTime.utc(2026, 3, 1, 12));
    final db = await FleetDatabase.open(path);
    return TestHarness._(
      db,
      clock,
      TelemetryIngestor(database: db, clock: clock),
      tempDir,
    );
  }

  /// Closes the database and reopens it from the same path, returning a
  /// harness backed by the file on disk. Only valid for [onDisk] harnesses.
  Future<TestHarness> reopen() async {
    if (_tempDir == null) {
      throw StateError('reopen() needs an on-disk harness');
    }
    final path = db.path;
    final now = clock.nowUtc();
    await db.dispose();

    final reopened = await FleetDatabase.open(path);
    final newClock = FixedClock(now);
    return TestHarness._(
      reopened,
      newClock,
      TelemetryIngestor(database: reopened, clock: newClock),
      _tempDir,
    );
  }

  Future<void> dispose() async {
    await db.dispose();
    if (_tempDir != null && _tempDir.existsSync()) {
      _tempDir.deleteSync(recursive: true);
    }
  }

  /// Runs a query and returns plain rows.
  Future<List<List<Object?>>> rows(String sql) async {
    final result = await db.connection.query(sql);
    try {
      return result.fetchAll();
    } finally {
      await result.dispose();
    }
  }

  Future<Object?> scalar(String sql) async {
    final all = await rows(sql);
    if (all.isEmpty || all.first.isEmpty) return null;
    return all.first.first;
  }

  Future<int> count(String sql) async => asInt(await scalar(sql));
}

/// DuckDB returns `int` for BIGINT but `BigInt` for UBIGINT/HUGEINT.
int asInt(Object? value) => switch (value) {
  final int i => i,
  final BigInt b => b.toInt(),
  final num n => n.toInt(),
  _ => -1,
};

/// Builds a packet with sensible defaults, so each test states only what it is
/// actually about.
TelemetryPacket packet({
  required String packetId,
  required DateTime eventTs,
  String vehicleId = 'V1',
  Map<SignalKind, double> signals = const {},
  GeoFix? location,
}) => TelemetryPacket(
  packetId: packetId,
  vehicleId: vehicleId,
  eventTs: eventTs,
  signals: signals,
  location: location,
);
