/// The DuckDB implementation of [FleetRepository].
///
/// Reads come straight out of the database — there is no in-memory list that
/// DuckDB shadows, which is the architectural requirement in §2 of the brief.
library;

import 'package:dart_duckdb/dart_duckdb.dart';

import '../../core/constants.dart';
import '../../domain/entities/fleet_view.dart';
import '../../domain/entities/signal_kind.dart';
import '../../domain/entities/signal_reading.dart';
import '../../domain/entities/vehicle_status.dart';
import '../../domain/repositories/alert_repository.dart';
import '../../domain/repositories/fleet_repository.dart';
import '../duckdb/fleet_database.dart';
import '../duckdb/queries/fleet_queries.dart';

final class DuckDbFleetRepository
    implements FleetRepository, FleetSnapshotSource {
  DuckDbFleetRepository(this._db);

  final FleetDatabase _db;

  Connection get _conn => _db.connection;

  @override
  Future<List<FleetListItem>> fleetList({
    required DateTime now,
    VehicleStatus? status,
  }) async {
    final freshFrom = now.subtract(FleetThresholds.signalStaleAfter);
    final onlineFrom = now.subtract(FleetThresholds.offlineAfter);

    final stmt = await _conn.prepare(
      status == null ? selectFleetList : selectFleetListFiltered,
    );
    stmt
      ..bind(freshFrom, 1)
      ..bind(freshFrom, 2)
      ..bind(onlineFrom, 3);
    if (status != null) stmt.bind(_wireName(status), 4);

    final result = await stmt.execute();
    try {
      return [
        for (final row in result.fetchAll())
          FleetListItem(
            vehicleId: row[0]! as String,
            regNumber: row[1]! as String,
            model: row[2]! as String,
            status: _statusFromWire(row[3]! as String),
            soc: _toDouble(row[4]),
            socEventTs: row[5] as DateTime?,
            rangeKm: _toDouble(row[6]),
            lastPing: row[7] as DateTime?,
            openAlertCount: _toInt(row[8]),
            hasCriticalAlert: _toInt(row[9]) != 0,
          ),
      ];
    } finally {
      await result.dispose();
      await stmt.dispose();
    }
  }

  @override
  Future<Map<VehicleStatus, int>> statusCounts({required DateTime now}) async {
    final freshFrom = now.subtract(FleetThresholds.signalStaleAfter);
    final onlineFrom = now.subtract(FleetThresholds.offlineAfter);

    final stmt = await _conn.prepare(selectStatusCounts);
    stmt
      ..bind(freshFrom, 1)
      ..bind(freshFrom, 2)
      ..bind(onlineFrom, 3);

    final result = await stmt.execute();
    try {
      return {
        for (final row in result.fetchAll())
          _statusFromWire(row[0]! as String): _toInt(row[1]),
      };
    } finally {
      await result.dispose();
      await stmt.dispose();
    }
  }

  @override
  Future<Map<String, VehicleSnapshot>> allVehicleSnapshots() async {
    final result = await _conn.query(selectAllLatestReadings);
    try {
      final byVehicle = <String, Map<SignalKind, SignalReading>>{};
      for (final row in result.fetchAll()) {
        final kind = SignalKind.fromWireName(row[1]! as String);
        // Written by a newer build. Skipping keeps the rest usable rather than
        // failing the whole sweep.
        if (kind == null) continue;

        final vehicleId = row[0]! as String;
        (byVehicle[vehicleId] ??= {})[kind] = SignalReading(
          kind: kind,
          value: _toDouble(row[2])!,
          eventTs: row[3]! as DateTime,
        );
      }
      return {
        for (final entry in byVehicle.entries)
          entry.key: VehicleSnapshot(
            vehicleId: entry.key,
            readings: entry.value,
          ),
      };
    } finally {
      await result.dispose();
    }
  }

  @override
  Future<VehicleReadings?> vehicleReadings(String vehicleId) async {
    final stmt = await _conn.prepare(selectVehicleReadings);
    stmt.bind(vehicleId, 1);

    final result = await stmt.execute();
    try {
      final rows = result.fetchAll();
      if (rows.isEmpty) return null;

      final readings = <SignalKind, SignalReading>{};
      for (final row in rows) {
        // A LEFT JOIN against a vehicle with no readings yields one row of
        // nulls. That is a real vehicle with nothing reported, not a miss.
        final signalName = row[2] as String?;
        if (signalName == null) continue;

        final kind = SignalKind.fromWireName(signalName);
        // An unrecognised signal name means the database was written by a
        // newer build. Skipping is better than throwing: the rest of the
        // register is still useful.
        if (kind == null) continue;

        readings[kind] = SignalReading(
          kind: kind,
          value: _toDouble(row[3])!,
          eventTs: row[4]! as DateTime,
        );
      }

      return VehicleReadings(
        vehicle: Vehicle(
          vehicleId: vehicleId,
          regNumber: rows.first[0]! as String,
          model: rows.first[1]! as String,
        ),
        snapshot: VehicleSnapshot(vehicleId: vehicleId, readings: readings),
      );
    } finally {
      await result.dispose();
      await stmt.dispose();
    }
  }

  @override
  Future<List<SocSample>> socHistory(
    String vehicleId, {
    required DateTime since,
    int maxPoints = 200,
  }) async {
    final stmt = await _conn.prepare(selectSocHistory);
    stmt
      ..bind(maxPoints, 1)
      ..bind(vehicleId, 2)
      ..bind(since, 3);

    final result = await stmt.execute();
    try {
      return [
        for (final row in result.fetchAll())
          SocSample(
            eventTs: row[0]! as DateTime,
            value: _toDouble(row[1])!,
          ),
      ];
    } finally {
      await result.dispose();
      await stmt.dispose();
    }
  }

  @override
  Future<void> upsertVehicles(List<Vehicle> vehicles) async {
    if (vehicles.isEmpty) return;

    const chunkSize = 200;
    for (var start = 0; start < vehicles.length; start += chunkSize) {
      final end = start + chunkSize < vehicles.length
          ? start + chunkSize
          : vehicles.length;
      final chunk = vehicles.sublist(start, end);
      final placeholders =
          List.filled(chunk.length, '(?, ?, ?, ?)').join(', ');

      final stmt = await _conn.prepare('''
        INSERT INTO vehicles (vehicle_id, reg_number, model, created_at)
        VALUES $placeholders
        ON CONFLICT (vehicle_id) DO UPDATE SET
          reg_number = excluded.reg_number,
          model      = excluded.model
      ''');
      var index = 1;
      for (final vehicle in chunk) {
        stmt.bind(vehicle.vehicleId, index++);
        stmt.bind(vehicle.regNumber, index++);
        stmt.bind(vehicle.model, index++);
        stmt.bind(DateTime.now().toUtc(), index++);
      }
      await (await stmt.execute()).dispose();
      await stmt.dispose();
    }
  }

  @override
  Future<int> vehicleCount() async {
    final result = await _conn.query('SELECT COUNT(*) FROM vehicles');
    try {
      return _toInt(result.fetchAll().first.first);
    } finally {
      await result.dispose();
    }
  }

  static String _wireName(VehicleStatus status) => status.name;

  static VehicleStatus _statusFromWire(String wire) =>
      VehicleStatus.values.firstWhere(
        (s) => s.name == wire,
        orElse: () => VehicleStatus.unknown,
      );

  /// DuckDB hands back `int` for BIGINT and `BigInt` for the wider types, so
  /// every numeric read is normalised rather than blind-cast.
  static double? _toDouble(Object? value) => switch (value) {
    null => null,
    final double d => d,
    final int i => i.toDouble(),
    final BigInt b => b.toDouble(),
    _ => null,
  };

  static int _toInt(Object? value) => switch (value) {
    final int i => i,
    final BigInt b => b.toInt(),
    final num n => n.toInt(),
    _ => 0,
  };
}
