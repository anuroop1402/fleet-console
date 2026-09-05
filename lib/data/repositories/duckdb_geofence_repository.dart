/// DuckDB implementations for geofences, trips and the replay writer.
library;

import 'dart:math';

import 'package:dart_duckdb/dart_duckdb.dart';

import '../../domain/entities/geofence.dart';
import '../../domain/repositories/geofence_repository.dart';
import '../../domain/usecases/replay_trips.dart';
import '../duckdb/fleet_database.dart';

final class DuckDbGeofenceRepository
    implements
        GeofenceRepository,
        TripRepository,
        LocationFixSource,
        DerivedTripWriter {
  DuckDbGeofenceRepository(this._db);

  final FleetDatabase _db;

  Connection get _conn => _db.connection;

  final Random _entropy = Random();

  /// Identity for a fence or one of its versions.
  ///
  /// Deliberately carries entropy, unlike [tripIdFor]. Trips are *derived*, so
  /// their ids must be reproducible or every replay would create duplicates.
  /// Geofences are *authored* — a human pressed a button — so nothing
  /// recomputes them, and the only requirement is uniqueness.
  ///
  /// A timestamp alone is not enough: seeding three fences in a loop, or two
  /// edits inside the same microsecond, collides on the primary key. That is
  /// not hypothetical; it is how this was found.
  String _newId(String prefix, DateTime at) =>
      '$prefix-${at.microsecondsSinceEpoch}-'
      '${_entropy.nextInt(1 << 32).toRadixString(36)}';

  static const String _versionColumns = '''
    version_id, geofence_id, name, latitude, longitude, radius_m,
    valid_from, valid_to, is_active
  ''';

  // ---------------------------------------------------------------- fences

  @override
  Future<List<GeofenceVersion>> allVersions() =>
      _selectVersions('SELECT $_versionColumns FROM geofence_versions');

  @override
  Future<List<GeofenceVersion>> currentVersions() => _selectVersions(
    'SELECT $_versionColumns FROM geofence_versions '
    'WHERE valid_to IS NULL AND is_active ORDER BY name',
  );

  @override
  Future<GeofenceVersion> create({
    required String name,
    required double latitude,
    required double longitude,
    required double radiusMetres,
    required DateTime at,
  }) async {
    final geofenceId = _newId('gf', at);
    final version = GeofenceVersion(
      geofenceId: geofenceId,
      versionId: _newId('${geofenceId}v', at),
      name: name,
      latitude: latitude,
      longitude: longitude,
      radiusMetres: radiusMetres,
      validFrom: at,
    );

    await _conn.execute('BEGIN TRANSACTION');
    try {
      final stmt = await _conn.prepare(
        'INSERT INTO geofences (geofence_id, created_at) VALUES (?, ?)',
      );
      stmt
        ..bind(geofenceId, 1)
        ..bind(at, 2);
      await (await stmt.execute()).dispose();
      await stmt.dispose();

      await _insertVersion(version, at);
      await _conn.execute('COMMIT');
      return version;
    } on Object {
      await _conn.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<GeofenceVersion> edit({
    required String geofenceId,
    required String name,
    required double latitude,
    required double longitude,
    required double radiusMetres,
    required DateTime at,
  }) async {
    // Close the current version and open a new one. Never an UPDATE of the
    // geometry: an in-place edit would retroactively change what every past
    // trip means, because history is judged against the version live at the
    // fix's event time.
    await _conn.execute('BEGIN TRANSACTION');
    try {
      await _closeCurrentVersion(geofenceId, at);

      final version = GeofenceVersion(
        geofenceId: geofenceId,
        versionId: _newId('${geofenceId}v', at),
        name: name,
        latitude: latitude,
        longitude: longitude,
        radiusMetres: radiusMetres,
        validFrom: at,
      );
      await _insertVersion(version, at);
      await _conn.execute('COMMIT');
      return version;
    } on Object {
      await _conn.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> deactivate({
    required String geofenceId,
    required DateTime at,
  }) async {
    // Closed, not deleted. The rows stay so trip history keeps resolving.
    await _closeCurrentVersion(geofenceId, at);
  }

  @override
  Future<void> reactivate({
    required String geofenceId,
    required DateTime at,
  }) async {
    final previous = await _selectVersions(
      'SELECT $_versionColumns FROM geofence_versions '
      "WHERE geofence_id = '$geofenceId' ORDER BY valid_from DESC LIMIT 1",
    );
    if (previous.isEmpty) return;

    final last = previous.first;
    await _insertVersion(
      GeofenceVersion(
        geofenceId: geofenceId,
        versionId: _newId('${geofenceId}v', at),
        name: last.name,
        latitude: last.latitude,
        longitude: last.longitude,
        radiusMetres: last.radiusMetres,
        validFrom: at,
      ),
      at,
    );
  }

  Future<void> _closeCurrentVersion(String geofenceId, DateTime at) async {
    final stmt = await _conn.prepare(
      'UPDATE geofence_versions SET valid_to = ? '
      'WHERE geofence_id = ? AND valid_to IS NULL',
    );
    stmt
      ..bind(at, 1)
      ..bind(geofenceId, 2);
    await (await stmt.execute()).dispose();
    await stmt.dispose();
  }

  Future<void> _insertVersion(GeofenceVersion version, DateTime at) async {
    final stmt = await _conn.prepare('''
      INSERT INTO geofence_versions (
        version_id, geofence_id, name, latitude, longitude, radius_m,
        valid_from, valid_to, is_active, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''');
    var i = 1;
    stmt.bind(version.versionId, i++);
    stmt.bind(version.geofenceId, i++);
    stmt.bind(version.name, i++);
    stmt.bind(version.latitude, i++);
    stmt.bind(version.longitude, i++);
    stmt.bind(version.radiusMetres, i++);
    stmt.bind(version.validFrom, i++);
    stmt.bind(version.validTo, i++);
    stmt.bind(version.isActive, i++);
    stmt.bind(at, i++);
    await (await stmt.execute()).dispose();
    await stmt.dispose();
  }

  Future<List<GeofenceVersion>> _selectVersions(String sql) async {
    final result = await _conn.query(sql);
    try {
      return [
        for (final row in result.fetchAll())
          GeofenceVersion(
            versionId: row[0]! as String,
            geofenceId: row[1]! as String,
            name: row[2]! as String,
            latitude: _toDouble(row[3])!,
            longitude: _toDouble(row[4])!,
            radiusMetres: _toDouble(row[5])!,
            validFrom: row[6]! as DateTime,
            validTo: row[7] as DateTime?,
            isActive: (row[8] as bool?) ?? true,
          ),
      ];
    } finally {
      await result.dispose();
    }
  }

  // ---------------------------------------------------------------- fixes

  @override
  Future<List<LocationFix>> fixesFor(String vehicleId, {DateTime? from}) async {
    final stmt = await _conn.prepare('''
      SELECT vehicle_id, event_ts, ingested_ts, packet_id,
             latitude, longitude, accuracy_m
      FROM location_fixes
      WHERE vehicle_id = ? AND event_ts >= ?
      ORDER BY event_ts, ingested_ts, packet_id
    ''');
    stmt
      ..bind(vehicleId, 1)
      ..bind(from ?? DateTime.utc(1970), 2);

    final result = await stmt.execute();
    try {
      return [
        for (final row in result.fetchAll())
          LocationFix(
            vehicleId: row[0]! as String,
            eventTs: row[1]! as DateTime,
            ingestedTs: row[2]! as DateTime,
            packetId: row[3]! as String,
            latitude: _toDouble(row[4])!,
            longitude: _toDouble(row[5])!,
            accuracyMetres: _toDouble(row[6])!,
          ),
      ];
    } finally {
      await result.dispose();
      await stmt.dispose();
    }
  }

  @override
  Future<List<String>> vehiclesWithFixesSince(DateTime since) async {
    final stmt = await _conn.prepare(
      'SELECT DISTINCT vehicle_id FROM location_fixes WHERE event_ts >= ? '
      'ORDER BY vehicle_id',
    );
    stmt.bind(since, 1);
    final result = await stmt.execute();
    try {
      return [for (final row in result.fetchAll()) row.first! as String];
    } finally {
      await result.dispose();
      await stmt.dispose();
    }
  }

  // -------------------------------------------------------------- derived

  @override
  Future<void> replaceDerived({
    required String vehicleId,
    required DateTime from,
    required List<GeofenceVisit> visits,
    required List<Trip> trips,
  }) async {
    await _conn.execute('BEGIN TRANSACTION');
    try {
      // Delete then insert, in one transaction. A replay can produce *fewer*
      // rows than before — a late fix revealing a truck never really left
      // removes a trip that used to exist — and an upsert would strand it.
      for (final table in ['geofence_visits', 'trips']) {
        final column = table == 'trips' ? 'started_at' : 'entered_at';
        final stmt = await _conn.prepare(
          'DELETE FROM $table WHERE vehicle_id = ? AND $column >= ?',
        );
        stmt
          ..bind(vehicleId, 1)
          ..bind(from, 2);
        await (await stmt.execute()).dispose();
        await stmt.dispose();
      }

      await _insertVisits(visits);
      await _insertTrips(trips);
      await _conn.execute('COMMIT');
    } on Object {
      await _conn.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> _insertVisits(List<GeofenceVisit> visits) async {
    if (visits.isEmpty) return;
    final placeholders =
        List.filled(visits.length, '(?, ?, ?, ?, ?, ?)').join(', ');
    final stmt = await _conn.prepare(
      'INSERT INTO geofence_visits VALUES $placeholders',
    );
    var i = 1;
    for (final visit in visits) {
      stmt.bind(visit.vehicleId, i++);
      stmt.bind(visit.geofenceId, i++);
      stmt.bind(visit.versionId, i++);
      stmt.bind(visit.enteredAt, i++);
      stmt.bind(visit.exitedAt, i++);
      stmt.bind(visit.inferredDuringGap, i++);
    }
    await (await stmt.execute()).dispose();
    await stmt.dispose();
  }

  Future<void> _insertTrips(List<Trip> trips) async {
    if (trips.isEmpty) return;
    final placeholders = List.filled(
      trips.length,
      '(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    ).join(', ');
    final stmt = await _conn.prepare('INSERT INTO trips VALUES $placeholders');
    var i = 1;
    for (final trip in trips) {
      stmt.bind(trip.tripId, i++);
      stmt.bind(trip.vehicleId, i++);
      stmt.bind(trip.status.wireName, i++);
      stmt.bind(trip.startedAt, i++);
      stmt.bind(trip.originGeofenceId, i++);
      stmt.bind(trip.originVersionId, i++);
      stmt.bind(trip.endedAt, i++);
      stmt.bind(trip.destinationGeofenceId, i++);
      stmt.bind(trip.destinationVersionId, i++);
      stmt.bind(trip.destinationUnknown, i++);
      stmt.bind(trip.inferredDuringGap, i++);
    }
    await (await stmt.execute()).dispose();
    await stmt.dispose();
  }

  // ----------------------------------------------------------------- read

  static const String _tripColumns = '''
    trip_id, vehicle_id, status, started_at, origin_geofence_id,
    origin_version_id, ended_at, destination_geofence_id,
    destination_version_id, destination_unknown, inferred_during_gap
  ''';

  @override
  Future<List<Trip>> tripsFor(String vehicleId, {int limit = 50}) async {
    final stmt = await _conn.prepare(
      'SELECT $_tripColumns FROM trips WHERE vehicle_id = ? '
      'ORDER BY started_at DESC LIMIT ?',
    );
    stmt
      ..bind(vehicleId, 1)
      ..bind(limit, 2);
    return _readTrips(stmt);
  }

  @override
  Future<List<Trip>> recentTrips({int limit = 100}) async {
    final stmt = await _conn.prepare(
      'SELECT $_tripColumns FROM trips ORDER BY started_at DESC LIMIT ?',
    );
    stmt.bind(limit, 1);
    return _readTrips(stmt);
  }

  Future<List<Trip>> _readTrips(PreparedStatement stmt) async {
    final result = await stmt.execute();
    try {
      return [
        for (final row in result.fetchAll())
          Trip(
            tripId: row[0]! as String,
            vehicleId: row[1]! as String,
            status: row[2] == TripStatus.completed.wireName
                ? TripStatus.completed
                : TripStatus.inProgress,
            startedAt: row[3]! as DateTime,
            originGeofenceId: row[4] as String?,
            originVersionId: row[5] as String?,
            endedAt: row[6] as DateTime?,
            destinationGeofenceId: row[7] as String?,
            destinationVersionId: row[8] as String?,
            destinationUnknown: (row[9] as bool?) ?? false,
            inferredDuringGap: (row[10] as bool?) ?? false,
          ),
      ];
    } finally {
      await result.dispose();
      await stmt.dispose();
    }
  }

  @override
  Future<List<GeofenceVisit>> visitsFor(
    String vehicleId, {
    int limit = 50,
  }) async {
    final stmt = await _conn.prepare('''
      SELECT vehicle_id, geofence_id, version_id, entered_at, exited_at,
             inferred_during_gap
      FROM geofence_visits WHERE vehicle_id = ?
      ORDER BY entered_at DESC LIMIT ?
    ''');
    stmt
      ..bind(vehicleId, 1)
      ..bind(limit, 2);
    final result = await stmt.execute();
    try {
      return [
        for (final row in result.fetchAll())
          GeofenceVisit(
            vehicleId: row[0]! as String,
            geofenceId: row[1]! as String,
            versionId: row[2]! as String,
            enteredAt: row[3]! as DateTime,
            exitedAt: row[4] as DateTime?,
            inferredDuringGap: (row[5] as bool?) ?? false,
          ),
      ];
    } finally {
      await result.dispose();
      await stmt.dispose();
    }
  }

  @override
  Future<Map<String, int>> vehicleCountsByGeofence() async {
    // Open visits only: a vehicle is "in" a fence while its visit has not
    // closed. Counting closed visits would report every truck that ever
    // visited, which is a different and much less useful question.
    final result = await _conn.query('''
      SELECT geofence_id, COUNT(DISTINCT vehicle_id)
      FROM geofence_visits WHERE exited_at IS NULL
      GROUP BY geofence_id
    ''');
    try {
      return {
        for (final row in result.fetchAll())
          row[0]! as String: _toInt(row[1]),
      };
    } finally {
      await result.dispose();
    }
  }

  @override
  Future<Map<String, String>> currentGeofenceByVehicle() async {
    // Overlaps resolved the same way the domain does it: the most specific
    // fence wins, then the lowest id. Done in SQL because it feeds a list.
    final result = await _conn.query('''
      SELECT vehicle_id, geofence_id FROM (
        SELECT v.vehicle_id, v.geofence_id,
               ROW_NUMBER() OVER (
                 PARTITION BY v.vehicle_id
                 ORDER BY gv.radius_m ASC, v.geofence_id ASC
               ) AS rn
        FROM geofence_visits v
        JOIN geofence_versions gv ON gv.version_id = v.version_id
        WHERE v.exited_at IS NULL
      ) WHERE rn = 1
    ''');
    try {
      return {
        for (final row in result.fetchAll())
          row[0]! as String: row[1]! as String,
      };
    } finally {
      await result.dispose();
    }
  }

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
