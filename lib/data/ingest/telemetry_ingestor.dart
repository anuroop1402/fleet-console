/// Writes telemetry into DuckDB, correctly, under adversarial arrival.
///
/// Packets arrive late, out of order and duplicated. This is the one place that
/// deals with all three, so that everything downstream can assume a clean,
/// totally-ordered event log.
library;

import 'package:dart_duckdb/dart_duckdb.dart';

import '../../core/clock.dart';
import '../../core/constants.dart';
import '../../domain/entities/telemetry_packet.dart';
import '../duckdb/fleet_database.dart';
import '../duckdb/schema.dart';
import 'ingest_report.dart';

/// One flattened `(packet, signal)` row, ready to stage.
final class _SignalRow {
  const _SignalRow({
    required this.vehicleId,
    required this.signal,
    required this.eventTs,
    required this.packetId,
    required this.value,
  });

  final String vehicleId;
  final String signal;
  final DateTime eventTs;
  final String packetId;
  final double value;

  /// Identity of an *exact* duplicate: the same packet delivered twice.
  ///
  /// Deliberately includes [packetId]. Two different packets reporting the same
  /// signal at the same event time are a *conflict*, not a duplicate — both are
  /// real observations and both are kept in the log. The deterministic
  /// tie-break decides which one is "latest"; discarding one at ingest would
  /// throw away evidence.
  String get exactKey =>
      '$vehicleId $signal ${eventTs.microsecondsSinceEpoch} $packetId';
}

final class _RejectedRow {
  const _RejectedRow({
    required this.reason,
    required this.detail,
    this.vehicleId,
    this.packetId,
    this.signal,
    this.eventTs,
  });

  final RejectionReason reason;
  final String detail;
  final String? vehicleId;
  final String? packetId;
  final String? signal;
  final DateTime? eventTs;
}

final class TelemetryIngestor {
  TelemetryIngestor({required FleetDatabase database, required Clock clock})
    : _db = database,
      _clock = clock;

  final FleetDatabase _db;

  /// Injected, never `DateTime.now()`. Staleness, retention and clock-skew
  /// rejection are all functions of "now", so tests have to control it.
  final Clock _clock;

  Connection get _conn => _db.connection;

  /// How many rows are bound into a single `INSERT ... VALUES` statement.
  ///
  /// Every `execute` is a round-trip to the connection's isolate, so binding
  /// one row at a time would cost one round-trip per reading. Batching trades a
  /// larger parameter list for far fewer crossings.
  static const int _chunkRows = 200;

  Future<IngestReport> ingest(List<TelemetryPacket> packets) async {
    if (packets.isEmpty) return IngestReport.empty;

    final now = _clock.nowUtc();
    final notAfter = now.add(IngestPolicy.maxClockSkewAhead);
    final signalsNotBefore = now.subtract(RetentionPolicy.rawSignals);
    final fixesNotBefore = now.subtract(RetentionPolicy.rawLocationFixes);

    final signalRows = <_SignalRow>[];
    final fixPackets = <TelemetryPacket>[];
    final rejects = <_RejectedRow>[];
    final seenExact = <String>{};

    for (final packet in packets) {
      if (!packet.eventTs.isUtc) {
        // A programming error, not bad data. Failing loudly is the only way
        // this stays caught: a local DateTime is stored 5h30m early on an IST
        // device and nothing downstream can detect it.
        throw ArgumentError.value(
          packet.eventTs,
          'eventTs',
          'Packet ${packet.packetId} has a non-UTC event time. '
              'Convert with .toUtc() at the edge.',
        );
      }

      if (packet.isEmpty) {
        rejects.add(
          _RejectedRow(
            reason: RejectionReason.malformed,
            detail: 'no signals and no location',
            vehicleId: packet.vehicleId,
            packetId: packet.packetId,
            eventTs: packet.eventTs,
          ),
        );
        continue;
      }

      if (packet.eventTs.isAfter(notAfter)) {
        rejects.add(
          _RejectedRow(
            reason: RejectionReason.clockSkewAhead,
            detail:
                'event time ${packet.eventTs.toIso8601String()} is more than '
                '${IngestPolicy.maxClockSkewAhead.inMinutes} min ahead of '
                '${now.toIso8601String()}',
            vehicleId: packet.vehicleId,
            packetId: packet.packetId,
            eventTs: packet.eventTs,
          ),
        );
        continue;
      }

      for (final entry in packet.signals.entries) {
        final value = entry.value;

        if (value.isNaN || value.isInfinite) {
          rejects.add(
            _RejectedRow(
              reason: RejectionReason.malformed,
              detail: 'non-finite value for ${entry.key.wireName}',
              vehicleId: packet.vehicleId,
              packetId: packet.packetId,
              signal: entry.key.wireName,
              eventTs: packet.eventTs,
            ),
          );
          continue;
        }

        // Beyond retention it can never be replayed, so accepting it would
        // create a row that derived state cannot be rebuilt from.
        if (packet.eventTs.isBefore(signalsNotBefore)) {
          rejects.add(
            _RejectedRow(
              reason: RejectionReason.beyondRetention,
              detail:
                  'older than the ${RetentionPolicy.rawSignals.inDays}-day raw '
                  'signal window',
              vehicleId: packet.vehicleId,
              packetId: packet.packetId,
              signal: entry.key.wireName,
              eventTs: packet.eventTs,
            ),
          );
          continue;
        }

        final row = _SignalRow(
          vehicleId: packet.vehicleId,
          signal: entry.key.wireName,
          eventTs: packet.eventTs,
          packetId: packet.packetId,
          value: value,
        );

        if (!seenExact.add(row.exactKey)) {
          rejects.add(
            _RejectedRow(
              reason: RejectionReason.duplicate,
              detail: 'repeated within the same batch',
              vehicleId: row.vehicleId,
              packetId: row.packetId,
              signal: row.signal,
              eventTs: row.eventTs,
            ),
          );
          continue;
        }

        signalRows.add(row);
      }

      if (packet.location != null) {
        if (packet.eventTs.isBefore(fixesNotBefore)) {
          rejects.add(
            _RejectedRow(
              reason: RejectionReason.beyondRetention,
              detail:
                  'older than the '
                  '${RetentionPolicy.rawLocationFixes.inDays}-day fix window',
              vehicleId: packet.vehicleId,
              packetId: packet.packetId,
              eventTs: packet.eventTs,
            ),
          );
        } else {
          fixPackets.add(packet);
        }
      }
    }

    await _conn.execute('BEGIN TRANSACTION');
    try {
      final signalsWritten = await _writeSignals(signalRows, now, rejects);
      final fixesWritten = await _writeFixes(fixPackets, now);
      await _writeRejections(rejects, now);
      await _conn.execute('COMMIT');

      final tally = <RejectionReason, int>{};
      for (final reject in rejects) {
        tally.update(reject.reason, (n) => n + 1, ifAbsent: () => 1);
      }

      return IngestReport(
        signalRowsWritten: signalsWritten,
        locationRowsWritten: fixesWritten,
        rejected: tally,
      );
    } on Object {
      await _conn.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<int> _writeSignals(
    List<_SignalRow> rows,
    DateTime ingestedTs,
    List<_RejectedRow> rejects,
  ) async {
    if (rows.isEmpty) return 0;

    await _conn.execute('''
      CREATE OR REPLACE TEMP TABLE staged_signals (
        vehicle_id  VARCHAR   NOT NULL,
        signal      VARCHAR   NOT NULL,
        event_ts    TIMESTAMP NOT NULL,
        ingested_ts TIMESTAMP NOT NULL,
        packet_id   VARCHAR   NOT NULL,
        value_num   DOUBLE    NOT NULL
      )
    ''');

    for (var start = 0; start < rows.length; start += _chunkRows) {
      final end = start + _chunkRows < rows.length
          ? start + _chunkRows
          : rows.length;
      final chunk = rows.sublist(start, end);
      final placeholders = List.filled(
        chunk.length,
        '(?, ?, ?, ?, ?, ?)',
      ).join(', ');

      final stmt = await _conn.prepare(
        'INSERT INTO staged_signals VALUES $placeholders',
      );
      var index = 1;
      for (final row in chunk) {
        stmt.bind(row.vehicleId, index++);
        stmt.bind(row.signal, index++);
        stmt.bind(row.eventTs, index++);
        stmt.bind(ingestedTs, index++);
        stmt.bind(row.packetId, index++);
        stmt.bind(row.value, index++);
      }
      await (await stmt.execute()).dispose();
      await stmt.dispose();
    }

    // Exact duplicates already in the log. The event_ts lower bound is what
    // keeps this cheap: DuckDB's zone maps skip row groups outside the range,
    // so the anti-join does not grow with the size of the log.
    final lookbackFrom = ingestedTs.subtract(IngestPolicy.duplicateLookback);

    final duplicates = await _countExistingDuplicates(lookbackFrom);
    for (var i = 0; i < duplicates; i++) {
      rejects.add(
        const _RejectedRow(
          reason: RejectionReason.duplicate,
          detail: 'already present in signal_readings',
        ),
      );
    }

    final insertStmt = await _conn.prepare('''
      INSERT INTO signal_readings
      SELECT s.* FROM staged_signals s
      WHERE NOT EXISTS (
        SELECT 1 FROM signal_readings r
        WHERE r.event_ts   >= ?
          AND r.vehicle_id  = s.vehicle_id
          AND r.signal      = s.signal
          AND r.event_ts    = s.event_ts
          AND r.packet_id   = s.packet_id
      )
    ''');
    insertStmt.bind(lookbackFrom, 1);
    await (await insertStmt.execute()).dispose();
    await insertStmt.dispose();

    await _refreshLatestReadings();

    return rows.length - duplicates;
  }

  Future<int> _countExistingDuplicates(DateTime lookbackFrom) async {
    final stmt = await _conn.prepare('''
      SELECT COUNT(*) FROM staged_signals s
      WHERE EXISTS (
        SELECT 1 FROM signal_readings r
        WHERE r.event_ts   >= ?
          AND r.vehicle_id  = s.vehicle_id
          AND r.signal      = s.signal
          AND r.event_ts    = s.event_ts
          AND r.packet_id   = s.packet_id
      )
    ''');
    stmt.bind(lookbackFrom, 1);
    final result = await stmt.execute();
    try {
      return _asInt(result.fetchAll().first.first);
    } finally {
      await result.dispose();
      await stmt.dispose();
    }
  }

  /// Advances `latest_readings` to the newest reading *by event time*.
  ///
  /// Two things make this correct rather than merely convenient:
  ///
  /// 1. The staged rows are collapsed to one row per `(vehicle, signal)` first.
  ///    `ON CONFLICT` cannot update the same target row twice in one statement,
  ///    and a batch routinely carries several readings for one signal.
  /// 2. The `WHERE` clause is the event-time guard. A late packet carrying an
  ///    *older* reading matches the conflict target but fails the guard, so it
  ///    lands in the log without ever becoming "current". This is the single
  ///    most important invariant in the ingest path.
  Future<void> _refreshLatestReadings() async {
    await _conn.execute('''
      INSERT INTO latest_readings
        (vehicle_id, signal, event_ts, ingested_ts, packet_id, value_num)
      SELECT vehicle_id, signal, event_ts, ingested_ts, packet_id, value_num
      FROM (
        SELECT *, ROW_NUMBER() OVER (
                    PARTITION BY vehicle_id, signal
                    ORDER BY event_ts DESC, ingested_ts DESC, packet_id DESC
                  ) AS rn
        FROM staged_signals
      )
      WHERE rn = 1
      ON CONFLICT (vehicle_id, signal) DO UPDATE SET
        event_ts    = excluded.event_ts,
        ingested_ts = excluded.ingested_ts,
        packet_id   = excluded.packet_id,
        value_num   = excluded.value_num
      WHERE excluded.event_ts > latest_readings.event_ts
         OR (excluded.event_ts = latest_readings.event_ts
             AND excluded.ingested_ts > latest_readings.ingested_ts)
         OR (excluded.event_ts = latest_readings.event_ts
             AND excluded.ingested_ts = latest_readings.ingested_ts
             AND excluded.packet_id > latest_readings.packet_id)
    ''');
  }

  Future<int> _writeFixes(
    List<TelemetryPacket> packets,
    DateTime ingestedTs,
  ) async {
    if (packets.isEmpty) return 0;

    var written = 0;
    for (var start = 0; start < packets.length; start += _chunkRows) {
      final end = start + _chunkRows < packets.length
          ? start + _chunkRows
          : packets.length;
      final chunk = packets.sublist(start, end);
      final placeholders = List.filled(
        chunk.length,
        '(?, ?, ?, ?, ?, ?, ?)',
      ).join(', ');

      final stmt = await _conn.prepare(
        'INSERT INTO location_fixes VALUES $placeholders',
      );
      var index = 1;
      for (final packet in chunk) {
        final fix = packet.location!;
        stmt.bind(packet.vehicleId, index++);
        stmt.bind(packet.eventTs, index++);
        stmt.bind(ingestedTs, index++);
        stmt.bind(packet.packetId, index++);
        stmt.bind(fix.latitude, index++);
        stmt.bind(fix.longitude, index++);
        stmt.bind(fix.accuracyMetres, index++);
      }
      await (await stmt.execute()).dispose();
      await stmt.dispose();
      written += chunk.length;
    }
    return written;
  }

  Future<void> _writeRejections(
    List<_RejectedRow> rejects,
    DateTime ingestedTs,
  ) async {
    if (rejects.isEmpty) return;

    for (var start = 0; start < rejects.length; start += _chunkRows) {
      final end = start + _chunkRows < rejects.length
          ? start + _chunkRows
          : rejects.length;
      final chunk = rejects.sublist(start, end);
      final placeholders = List.filled(
        chunk.length,
        '(?, ?, ?, ?, ?, ?, ?)',
      ).join(', ');

      final stmt = await _conn.prepare(
        'INSERT INTO rejected_packets VALUES $placeholders',
      );
      var index = 1;
      for (final reject in chunk) {
        stmt.bind(reject.vehicleId, index++);
        stmt.bind(reject.packetId, index++);
        stmt.bind(reject.signal, index++);
        stmt.bind(reject.eventTs, index++);
        stmt.bind(ingestedTs, index++);
        stmt.bind(reject.reason.wireName, index++);
        stmt.bind(reject.detail, index++);
      }
      await (await stmt.execute()).dispose();
      await stmt.dispose();
    }
  }

  static int _asInt(Object? value) => switch (value) {
    final int i => i,
    final BigInt b => b.toInt(),
    final num n => n.toInt(),
    _ => 0,
  };
}
