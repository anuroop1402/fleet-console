/// The DuckDB implementation of [AlertRepository].
library;

import 'package:dart_duckdb/dart_duckdb.dart';

import '../../domain/entities/alert.dart';
import '../../domain/entities/fleet_view.dart';
import '../../domain/repositories/alert_repository.dart';
import '../duckdb/fleet_database.dart';

final class DuckDbAlertRepository implements AlertRepository {
  DuckDbAlertRepository(this._db);

  final FleetDatabase _db;

  Connection get _conn => _db.connection;

  /// Column order is load-bearing: [_toAlert] reads by index.
  static const String _columns = '''
    vehicle_id, kind, opened_at, severity, resolved_at, dismissed_at,
    dismissed_at_severity, dismissal_reason, is_condition_stale,
    last_known_value, last_known_at
  ''';

  /// The same columns, qualified for the join in [visibleAlerts]. Spelled out
  /// rather than derived from [_columns] by string substitution — the SQL a
  /// reader needs to check should be readable, not reconstructed.
  static const String _alertColumns = '''
    a.vehicle_id, a.kind, a.opened_at, a.severity, a.resolved_at,
    a.dismissed_at, a.dismissed_at_severity, a.dismissal_reason,
    a.is_condition_stale, a.last_known_value, a.last_known_at
  ''';

  @override
  Future<List<Alert>> openAlerts() =>
      _select('SELECT $_columns FROM alerts WHERE resolved_at IS NULL');

  @override
  Future<List<AlertView>> visibleAlerts() async {
    // LEFT JOIN, not INNER: an alert for a vehicle missing from the register is
    // still a truck with a problem. Dropping it would hide the alert entirely,
    // which is the worst possible response to a data inconsistency.
    final result = await _conn.query('''
      SELECT $_alertColumns, v.reg_number
      FROM alerts a
      LEFT JOIN vehicles v ON v.vehicle_id = a.vehicle_id
      WHERE a.resolved_at IS NULL AND a.dismissed_at IS NULL
    ''');
    try {
      return result.fetchAll().map((row) {
        final alert = _toAlert(row);
        return AlertView(
          alert: alert,
          regNumber: (row[11] as String?) ?? alert.vehicleId,
        );
      }).toList();
    } finally {
      await result.dispose();
    }
  }

  @override
  Future<List<Alert>> alertHistory(String vehicleId, {int limit = 50}) async {
    final stmt = await _conn.prepare(
      'SELECT $_columns FROM alerts WHERE vehicle_id = ? '
      'ORDER BY opened_at DESC LIMIT ?',
    );
    stmt
      ..bind(vehicleId, 1)
      ..bind(limit, 2);
    final result = await stmt.execute();
    try {
      return result.fetchAll().map(_toAlert).toList();
    } finally {
      await result.dispose();
      await stmt.dispose();
    }
  }

  @override
  Future<void> applyTransitions({
    required List<Alert> upserts,
    required List<Alert> resolved,
    required DateTime now,
  }) async {
    if (upserts.isEmpty && resolved.isEmpty) return;

    // One transaction for the whole sweep. A half-applied pass would leave
    // alerts that disagree with the readings they were derived from, and the
    // next pass would have no way to tell.
    await _conn.execute('BEGIN TRANSACTION');
    try {
      await _upsert(upserts, now);
      await _resolve(resolved, now);
      await _conn.execute('COMMIT');
    } on Object {
      await _conn.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> saveDismissal(Alert alert) => _upsert([alert], alert.dismissedAt ?? DateTime.now().toUtc());

  Future<void> _upsert(List<Alert> alerts, DateTime now) async {
    if (alerts.isEmpty) return;

    const chunkSize = 100;
    for (var start = 0; start < alerts.length; start += chunkSize) {
      final end = start + chunkSize < alerts.length
          ? start + chunkSize
          : alerts.length;
      final chunk = alerts.sublist(start, end);
      final placeholders = List.filled(
        chunk.length,
        '(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      ).join(', ');

      // dismissed_at and friends are written unconditionally rather than
      // COALESCEd, because clearing them is a real transition: an escalation
      // past the dismissed severity has to be able to un-dismiss.
      final stmt = await _conn.prepare('''
        INSERT INTO alerts (
          vehicle_id, kind, opened_at, severity, resolved_at, dismissed_at,
          dismissed_at_severity, dismissal_reason, is_condition_stale,
          last_known_value, last_known_at, updated_at
        ) VALUES $placeholders
        ON CONFLICT (vehicle_id, kind, opened_at) DO UPDATE SET
          severity              = excluded.severity,
          dismissed_at          = excluded.dismissed_at,
          dismissed_at_severity = excluded.dismissed_at_severity,
          dismissal_reason      = excluded.dismissal_reason,
          is_condition_stale    = excluded.is_condition_stale,
          last_known_value      = excluded.last_known_value,
          last_known_at         = excluded.last_known_at,
          updated_at            = excluded.updated_at
      ''');

      var i = 1;
      for (final alert in chunk) {
        stmt.bind(alert.vehicleId, i++);
        stmt.bind(alert.kind.wireName, i++);
        stmt.bind(alert.openedAt, i++);
        stmt.bind(alert.severity.wireName, i++);
        stmt.bind(null, i++); // resolved_at — an upsert never resolves
        stmt.bind(alert.dismissedAt, i++);
        stmt.bind(alert.dismissedAtSeverity?.wireName, i++);
        stmt.bind(alert.dismissalReason?.wireName, i++);
        stmt.bind(alert.isConditionStale, i++);
        stmt.bind(alert.lastKnownValue, i++);
        stmt.bind(alert.lastKnownAt, i++);
        stmt.bind(now, i++);
      }
      await (await stmt.execute()).dispose();
      await stmt.dispose();
    }
  }

  Future<void> _resolve(List<Alert> alerts, DateTime now) async {
    for (final alert in alerts) {
      final stmt = await _conn.prepare('''
        UPDATE alerts SET resolved_at = ?, updated_at = ?
        WHERE vehicle_id = ? AND kind = ? AND opened_at = ?
      ''');
      stmt
        ..bind(now, 1)
        ..bind(now, 2)
        ..bind(alert.vehicleId, 3)
        ..bind(alert.kind.wireName, 4)
        ..bind(alert.openedAt, 5);
      await (await stmt.execute()).dispose();
      await stmt.dispose();
    }
  }

  Future<List<Alert>> _select(String sql) async {
    final result = await _conn.query(sql);
    try {
      return result.fetchAll().map(_toAlert).toList();
    } finally {
      await result.dispose();
    }
  }

  static Alert _toAlert(List<Object?> row) => Alert(
    vehicleId: row[0]! as String,
    kind: _kind(row[1]! as String),
    openedAt: row[2]! as DateTime,
    severity: _severity(row[3]! as String)!,
    dismissedAt: row[5] as DateTime?,
    dismissedAtSeverity: _severity(row[6] as String?),
    dismissalReason: _reason(row[7] as String?),
    isConditionStale: (row[8] as bool?) ?? false,
    lastKnownValue: _toDouble(row[9]),
    lastKnownAt: row[10] as DateTime?,
  );

  static AlertKind _kind(String wire) => AlertKind.values.firstWhere(
    (k) => k.wireName == wire,
    orElse: () => AlertKind.batterySoc,
  );

  static AlertSeverity? _severity(String? wire) {
    if (wire == null) return null;
    for (final severity in AlertSeverity.values) {
      if (severity.wireName == wire) return severity;
    }
    return null;
  }

  static DismissalReason? _reason(String? wire) {
    if (wire == null) return null;
    for (final reason in DismissalReason.values) {
      if (reason.wireName == wire) return reason;
    }
    return null;
  }

  static double? _toDouble(Object? value) => switch (value) {
    null => null,
    final double d => d,
    final int i => i.toDouble(),
    final BigInt b => b.toDouble(),
    _ => null,
  };
}
