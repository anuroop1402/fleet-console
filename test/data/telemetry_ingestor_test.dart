/// Ingest correctness under adversarial packet arrival.
///
/// Every test here maps to a specific claim in docs/01 §3. If one of these
/// fails, a documented resolution has silently stopped being true.
library;

import 'package:fleet_console/core/constants.dart';
import 'package:fleet_console/data/duckdb/schema.dart';
import 'package:fleet_console/domain/entities/signal_kind.dart';
import 'package:fleet_console/domain/entities/telemetry_packet.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_database.dart';

void main() {
  late TestHarness h;
  final now = DateTime.utc(2026, 3, 1, 12);

  setUp(() async => h = await TestHarness.inMemory(now: now));
  tearDown(() async => h.dispose());

  Future<double?> latestSoc({String vehicle = 'V1'}) async {
    final value = await h.scalar(
      "SELECT value_num FROM latest_readings "
      "WHERE vehicle_id = '$vehicle' AND signal = 'soc'",
    );
    return value as double?;
  }

  group('the happy path', () {
    test('writes readings to the log and to the projection', () async {
      final report = await h.ingestor.ingest([
        packet(
          packetId: 'p1',
          eventTs: now.subtract(const Duration(minutes: 1)),
          signals: {SignalKind.soc: 82, SignalKind.speed: 40},
        ),
      ]);

      expect(report.signalRowsWritten, 2);
      expect(report.rejectedTotal, 0);
      expect(await h.count('SELECT COUNT(*) FROM signal_readings'), 2);
      expect(await h.count('SELECT COUNT(*) FROM latest_readings'), 2);
      expect(await latestSoc(), 82);
    });

    test('stores location fixes separately from signals', () async {
      await h.ingestor.ingest([
        packet(
          packetId: 'p1',
          eventTs: now,
          signals: {SignalKind.soc: 50},
          location: const GeoFix(
            latitude: 12.97,
            longitude: 77.59,
            accuracyMetres: 8,
          ),
        ),
      ]);

      expect(await h.count('SELECT COUNT(*) FROM location_fixes'), 1);
      expect(await h.count('SELECT COUNT(*) FROM signal_readings'), 1);
    });

    test('ignition round-trips through the numeric column', () async {
      await h.ingestor.ingest([
        packet(
          packetId: 'p1',
          eventTs: now,
          signals: {SignalKind.ignition: true.asSignalValue},
        ),
      ]);

      final stored = await h.scalar(
        "SELECT value_num FROM latest_readings WHERE signal = 'ignition'",
      );
      expect((stored! as double).asIgnition, isTrue);
    });
  });

  group('event time beats arrival time', () {
    // The single most important invariant in the ingest path. A packet that
    // arrives later but was measured earlier must not become "current".
    test('a late packet with an older reading does not win', () async {
      await h.ingestor.ingest([
        packet(
          packetId: 'fresh',
          eventTs: now.subtract(const Duration(minutes: 1)),
          signals: {SignalKind.soc: 40},
        ),
      ]);
      expect(await latestSoc(), 40);

      // Arrives now, but was measured an hour ago.
      h.clock.advance(const Duration(seconds: 30));
      final report = await h.ingestor.ingest([
        packet(
          packetId: 'stale',
          eventTs: now.subtract(const Duration(hours: 1)),
          signals: {SignalKind.soc: 95},
        ),
      ]);

      expect(report.signalRowsWritten, 1, reason: 'it still belongs in the log');
      expect(await h.count('SELECT COUNT(*) FROM signal_readings'), 2);
      expect(
        await latestSoc(),
        40,
        reason: 'the older reading must not become current',
      );
    });

    test('a newer reading does advance the projection', () async {
      await h.ingestor.ingest([
        packet(
          packetId: 'p1',
          eventTs: now.subtract(const Duration(minutes: 5)),
          signals: {SignalKind.soc: 40},
        ),
      ]);
      await h.ingestor.ingest([
        packet(
          packetId: 'p2',
          eventTs: now.subtract(const Duration(minutes: 1)),
          signals: {SignalKind.soc: 38},
        ),
      ]);

      expect(await latestSoc(), 38);
    });

    test('out-of-order arrival within one batch still resolves to the '
        'newest event time', () async {
      await h.ingestor.ingest([
        packet(
          packetId: 'b',
          eventTs: now.subtract(const Duration(minutes: 1)),
          signals: {SignalKind.soc: 30},
        ),
        packet(
          packetId: 'a',
          eventTs: now.subtract(const Duration(minutes: 9)),
          signals: {SignalKind.soc: 70},
        ),
        packet(
          packetId: 'c',
          eventTs: now.subtract(const Duration(minutes: 5)),
          signals: {SignalKind.soc: 50},
        ),
      ]);

      expect(await h.count('SELECT COUNT(*) FROM signal_readings'), 3);
      expect(await latestSoc(), 30);
    });
  });

  group('duplicates', () {
    test('the same packet twice in one batch is written once', () async {
      final p = packet(
        packetId: 'p1',
        eventTs: now,
        signals: {SignalKind.soc: 55},
      );

      final report = await h.ingestor.ingest([p, p]);

      expect(report.signalRowsWritten, 1);
      expect(report.rejected[RejectionReason.duplicate], 1);
      expect(await h.count('SELECT COUNT(*) FROM signal_readings'), 1);
    });

    test('re-delivering a packet in a later batch is written once', () async {
      final p = packet(
        packetId: 'p1',
        eventTs: now,
        signals: {SignalKind.soc: 55},
      );

      await h.ingestor.ingest([p]);
      h.clock.advance(const Duration(minutes: 2));
      final second = await h.ingestor.ingest([p]);

      expect(second.signalRowsWritten, 0);
      expect(second.rejected[RejectionReason.duplicate], 1);
      expect(await h.count('SELECT COUNT(*) FROM signal_readings'), 1);
    });

    test('re-ingesting the whole batch changes nothing — ingest is '
        'idempotent', () async {
      final batch = [
        packet(
          packetId: 'p1',
          eventTs: now.subtract(const Duration(minutes: 3)),
          signals: {SignalKind.soc: 61, SignalKind.speed: 12},
        ),
        packet(
          packetId: 'p2',
          eventTs: now.subtract(const Duration(minutes: 2)),
          signals: {SignalKind.soc: 60},
        ),
      ];

      await h.ingestor.ingest(batch);
      final firstState = await h.rows(
        'SELECT vehicle_id, signal, event_ts, value_num FROM latest_readings '
        'ORDER BY signal',
      );

      h.clock.advance(const Duration(minutes: 1));
      await h.ingestor.ingest(batch);

      expect(await h.count('SELECT COUNT(*) FROM signal_readings'), 3);
      expect(
        await h.rows(
          'SELECT vehicle_id, signal, event_ts, value_num FROM latest_readings '
          'ORDER BY signal',
        ),
        firstState,
      );
    });

    test('two different packets at the same event time are both kept — '
        'that is a conflict, not a duplicate', () async {
      final report = await h.ingestor.ingest([
        packet(packetId: 'aaa', eventTs: now, signals: {SignalKind.soc: 10}),
        packet(packetId: 'bbb', eventTs: now, signals: {SignalKind.soc: 20}),
      ]);

      expect(report.signalRowsWritten, 2);
      expect(report.rejectedTotal, 0);
      expect(
        await latestSoc(),
        20,
        reason: 'tie broken deterministically by the higher packet_id',
      );
    });
  });

  group('packets the pipeline refuses', () {
    test('rejects an event time implausibly far in the future', () async {
      final report = await h.ingestor.ingest([
        packet(
          packetId: 'skewed',
          eventTs: now.add(const Duration(hours: 2)),
          signals: {SignalKind.soc: 99},
        ),
      ]);

      expect(report.signalRowsWritten, 0);
      expect(report.rejected[RejectionReason.clockSkewAhead], 1);
      expect(await h.count('SELECT COUNT(*) FROM signal_readings'), 0);
      expect(
        await latestSoc(),
        isNull,
        reason: 'a bad vehicle clock must never poison the projection',
      );
    });

    test('accepts an event time inside the skew tolerance', () async {
      final report = await h.ingestor.ingest([
        packet(
          packetId: 'slight',
          eventTs: now.add(IngestPolicy.maxClockSkewAhead ~/ 2),
          signals: {SignalKind.soc: 77},
        ),
      ]);

      expect(report.signalRowsWritten, 1);
      expect(await latestSoc(), 77);
    });

    test('rejects readings older than the retention window, because they '
        'could never be replayed', () async {
      final report = await h.ingestor.ingest([
        packet(
          packetId: 'ancient',
          eventTs: now
              .subtract(RetentionPolicy.rawSignals)
              .subtract(const Duration(days: 1)),
          signals: {SignalKind.soc: 44},
        ),
      ]);

      expect(report.rejected[RejectionReason.beyondRetention], 1);
      expect(await h.count('SELECT COUNT(*) FROM signal_readings'), 0);
    });

    test('rejects a packet carrying nothing', () async {
      final report = await h.ingestor.ingest([
        packet(packetId: 'empty', eventTs: now),
      ]);

      expect(report.rejected[RejectionReason.malformed], 1);
    });

    test('rejects non-finite values but keeps the rest of the packet',
        () async {
      final report = await h.ingestor.ingest([
        packet(
          packetId: 'p1',
          eventTs: now,
          signals: {SignalKind.soc: double.nan, SignalKind.speed: 30},
        ),
      ]);

      expect(report.rejected[RejectionReason.malformed], 1);
      expect(report.signalRowsWritten, 1);
      expect(await latestSoc(), isNull);
    });

    test('every rejection is recorded with a reason, never silently dropped',
        () async {
      await h.ingestor.ingest([
        packet(
          packetId: 'future',
          eventTs: now.add(const Duration(days: 1)),
          signals: {SignalKind.soc: 1},
        ),
        packet(packetId: 'empty', eventTs: now),
      ]);

      final reasons = await h.rows(
        'SELECT reason, COUNT(*) FROM rejected_packets GROUP BY reason '
        'ORDER BY reason',
      );
      expect(reasons, [
        ['clock_skew_ahead', 1],
        ['malformed', 1],
      ]);
    });

    test('a non-UTC event time is a programming error and throws', () async {
      expect(
        () => h.ingestor.ingest([
          TelemetryPacket(
            packetId: 'local',
            vehicleId: 'V1',
            eventTs: DateTime(2026, 3, 1, 12),
            signals: const {SignalKind.soc: 50},
          ),
        ]),
        throwsArgumentError,
      );
    });
  });

  group('transactions', () {
    test('an empty batch is a no-op', () async {
      final report = await h.ingestor.ingest([]);
      expect(report, isNotNull);
      expect(report.signalRowsWritten, 0);
      expect(await h.count('SELECT COUNT(*) FROM signal_readings'), 0);
    });

    test('vehicles are independent', () async {
      await h.ingestor.ingest([
        packet(
          packetId: 'a',
          vehicleId: 'V1',
          eventTs: now,
          signals: {SignalKind.soc: 10},
        ),
        packet(
          packetId: 'b',
          vehicleId: 'V2',
          eventTs: now,
          signals: {SignalKind.soc: 90},
        ),
      ]);

      expect(await latestSoc(vehicle: 'V1'), 10);
      expect(await latestSoc(vehicle: 'V2'), 90);
    });
  });
}
