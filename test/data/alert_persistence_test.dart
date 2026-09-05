/// Alerts, end to end through DuckDB.
///
/// Phase 2 proved the state machine in isolation. These tests prove the four
/// ambiguous cases survive a round-trip through the database — including the
/// one that matters most on a real device: a dismissed warning escalating to
/// critical *while the app was closed*.
library;

import 'package:fleet_console/data/repositories/duckdb_alert_repository.dart';
import 'package:fleet_console/data/repositories/duckdb_fleet_repository.dart';
import 'package:fleet_console/domain/entities/alert.dart';
import 'package:fleet_console/domain/entities/fleet_view.dart';
import 'package:fleet_console/domain/entities/signal_kind.dart';
import 'package:fleet_console/domain/usecases/evaluate_alerts.dart';
import 'package:fleet_console/domain/usecases/manage_alerts.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_database.dart';

void main() {
  final now = DateTime.utc(2026, 3, 1, 12);

  late TestHarness h;
  late DuckDbFleetRepository fleet;
  late DuckDbAlertRepository alerts;
  late EvaluateAlerts evaluate;

  Future<void> wire(TestHarness harness) async {
    h = harness;
    fleet = DuckDbFleetRepository(h.db);
    alerts = DuckDbAlertRepository(h.db);
    evaluate = EvaluateAlerts(
      alerts: alerts,
      snapshots: fleet,
      clock: h.clock,
    );
    await fleet.upsertVehicles(const [
      Vehicle(vehicleId: 'V1', regNumber: 'KA01AB1234', model: 'Truck'),
    ]);
  }

  setUp(() async => wire(await TestHarness.inMemory(now: now)));
  tearDown(() async => h.dispose());

  /// Reports SOC as of the harness clock, then re-evaluates.
  Future<void> reportSoc(double soc, {String packetId = 'p'}) async {
    await h.ingestor.ingest([
      packet(
        packetId: '$packetId-${h.clock.nowUtc().microsecondsSinceEpoch}',
        eventTs: h.clock.nowUtc().subtract(const Duration(seconds: 30)),
        signals: {SignalKind.soc: soc},
      ),
    ]);
    await evaluate();
  }

  Future<Alert?> openAlert() async {
    final open = await alerts.openAlerts();
    return open.isEmpty ? null : open.first;
  }

  group('opening and resolving', () {
    test('a fresh breach opens a warning', () async {
      await reportSoc(18);

      final alert = await openAlert();
      expect(alert, isNotNull);
      expect(alert!.kind, AlertKind.batterySoc);
      expect(alert.severity, AlertSeverity.warning);
      expect(alert.lastKnownValue, 18);
    });

    test('no alert when nothing breaches', () async {
      await reportSoc(80);
      expect(await alerts.openAlerts(), isEmpty);
    });

    test('recovery resolves it, and it leaves history behind', () async {
      await reportSoc(18);
      h.clock.advance(const Duration(minutes: 1));
      await reportSoc(60, packetId: 'q');

      expect(await alerts.openAlerts(), isEmpty);
      final history = await alerts.alertHistory('V1');
      expect(history, hasLength(1));
    });

    test('re-firing after a resolve opens a NEW instance', () async {
      await reportSoc(18);
      final first = (await openAlert())!;

      h.clock.advance(const Duration(minutes: 1));
      await reportSoc(60, packetId: 'q');

      h.clock.advance(const Duration(minutes: 1));
      await reportSoc(15, packetId: 'r');

      final second = (await openAlert())!;
      expect(second.openedAt.isAfter(first.openedAt), isTrue);
      expect(second.isDismissed, isFalse);
      expect(
        await alerts.alertHistory('V1'),
        hasLength(2),
        reason: 'two distinct occurrences, not one revived',
      );
    });

    test('only one alert of a kind is open at a time', () async {
      // The invariant the schema cannot express, so it is asserted here.
      for (final soc in [18.0, 16.0, 8.0, 9.0, 12.0]) {
        h.clock.advance(const Duration(minutes: 1));
        await reportSoc(soc, packetId: 's$soc');
      }

      final open = await alerts.openAlerts();
      expect(open.where((a) => a.kind == AlertKind.batterySoc), hasLength(1));
    });
  });

  group('escalation is one alert, not two', () {
    test('warning to critical keeps the same instance', () async {
      await reportSoc(18);
      final warning = (await openAlert())!;

      h.clock.advance(const Duration(minutes: 1));
      await reportSoc(8, packetId: 'q');

      final critical = (await openAlert())!;
      expect(critical.severity, AlertSeverity.critical);
      expect(critical.openedAt, warning.openedAt);
      expect(await alerts.alertHistory('V1'), hasLength(1));
    });
  });

  group('dismissal survives a restart', () {
    test('a dismissed alert stays hidden after reopening the database',
        () async {
      await wire(await TestHarness.onDisk(now: now));
      await reportSoc(18);

      final alert = (await openAlert())!;
      await DismissAlert(
        repository: alerts,
        clock: h.clock,
      )(alert, DismissalReason.onIt);

      expect(await alerts.visibleAlerts(), isEmpty);

      // Kill and reopen.
      final reopened = await h.reopen();
      addTearDown(reopened.dispose);
      final reopenedAlerts = DuckDbAlertRepository(reopened.db);

      expect(await reopenedAlerts.visibleAlerts(), isEmpty);
      final stillOpen = await reopenedAlerts.openAlerts();
      expect(stillOpen, hasLength(1));
      expect(stillOpen.first.dismissalReason, DismissalReason.onIt);
      expect(stillOpen.first.dismissedAtSeverity, AlertSeverity.warning);
    });

    test('a dismissed warning that escalates while the app was closed '
        'reappears at critical', () async {
      // The case that matters most in practice, and the one a purely in-memory
      // implementation would silently get wrong.
      await wire(await TestHarness.onDisk(now: now));
      await reportSoc(18);

      final alert = (await openAlert())!;
      await DismissAlert(
        repository: alerts,
        clock: h.clock,
      )(alert, DismissalReason.onIt);
      expect(await alerts.visibleAlerts(), isEmpty);

      final reopened = await h.reopen();
      addTearDown(reopened.dispose);

      final reopenedFleet = DuckDbFleetRepository(reopened.db);
      final reopenedAlerts = DuckDbAlertRepository(reopened.db);
      final reopenedEvaluate = EvaluateAlerts(
        alerts: reopenedAlerts,
        snapshots: reopenedFleet,
        clock: reopened.clock,
      );

      reopened.clock.advance(const Duration(minutes: 2));
      await reopened.ingestor.ingest([
        packet(
          packetId: 'worse',
          eventTs: reopened.clock.nowUtc().subtract(const Duration(seconds: 5)),
          signals: {SignalKind.soc: 7},
        ),
      ]);
      final summary = await reopenedEvaluate();

      final visible = await reopenedAlerts.visibleAlerts();
      expect(visible, hasLength(1));
      expect(visible.first.alert.severity, AlertSeverity.critical);
      expect(visible.first.alert.isDismissed, isFalse);
      expect(
        visible.first.regNumber,
        'KA01AB1234',
        reason: 'the alerts screen names trucks by plate, not internal id',
      );
      expect(summary.unDismissed, 1);
    });

    test('a dismissed critical that recovers to warning stays hidden',
        () async {
      await reportSoc(8);
      final critical = (await openAlert())!;
      await DismissAlert(
        repository: alerts,
        clock: h.clock,
      )(critical, DismissalReason.onIt);

      h.clock.advance(const Duration(minutes: 1));
      await reportSoc(15, packetId: 'q');

      expect(await alerts.visibleAlerts(), isEmpty);
      final open = await alerts.openAlerts();
      expect(open.first.severity, AlertSeverity.warning);
      expect(open.first.isDismissed, isTrue);
    });

    test('recovery resolves a dismissed alert', () async {
      await reportSoc(18);
      final alert = (await openAlert())!;
      await DismissAlert(
        repository: alerts,
        clock: h.clock,
      )(alert, DismissalReason.wrongAlert);

      h.clock.advance(const Duration(minutes: 1));
      await reportSoc(70, packetId: 'q');

      expect(await alerts.openAlerts(), isEmpty);
    });
  });

  group('staleness', () {
    test('an alert whose reading goes stale stays open and is flagged',
        () async {
      await reportSoc(8);
      expect((await openAlert())!.isConditionStale, isFalse);

      // No new packet — only the clock moves.
      h.clock.advance(const Duration(hours: 2));
      final summary = await evaluate();

      final alert = (await openAlert())!;
      expect(alert.isConditionStale, isTrue);
      expect(alert.severity, AlertSeverity.critical);
      expect(alert.lastKnownValue, 8);
      expect(summary.markedStale, 1);
      expect(
        summary.resolved,
        0,
        reason: 'going quiet is not evidence the battery recovered',
      );
    });

    test('the stale flag clears when readings resume', () async {
      await reportSoc(8);
      h.clock.advance(const Duration(hours: 2));
      await evaluate();
      expect((await openAlert())!.isConditionStale, isTrue);

      await reportSoc(9, packetId: 'q');
      expect((await openAlert())!.isConditionStale, isFalse);
    });
  });

  group('undo', () {
    test('restores the alert inside the window', () async {
      await reportSoc(18);
      final alert = (await openAlert())!;

      final dismissed = await DismissAlert(
        repository: alerts,
        clock: h.clock,
      )(alert, DismissalReason.onIt);
      expect(await alerts.visibleAlerts(), isEmpty);

      h.clock.advance(const Duration(seconds: 3));
      final restored = await UndoAlertDismissal(
        repository: alerts,
        clock: h.clock,
      )(dismissed);

      expect(restored, isNotNull);
      expect(await alerts.visibleAlerts(), hasLength(1));
    });

    test('refuses after the window, and the alert stays dismissed', () async {
      await reportSoc(18);
      final alert = (await openAlert())!;

      final dismissed = await DismissAlert(
        repository: alerts,
        clock: h.clock,
      )(alert, DismissalReason.onIt);

      h.clock.advance(const Duration(seconds: 30));
      final restored = await UndoAlertDismissal(
        repository: alerts,
        clock: h.clock,
      )(dismissed);

      expect(restored, isNull);
      expect(await alerts.visibleAlerts(), isEmpty);
    });
  });

  group('the fleet list badge', () {
    test('counts open undismissed alerts, and flags critical', () async {
      await reportSoc(8);

      final rows = await fleet.fleetList(now: h.clock.nowUtc());
      final v1 = rows.firstWhere((r) => r.vehicleId == 'V1');
      expect(v1.openAlertCount, 1);
      expect(v1.hasCriticalAlert, isTrue);
    });

    test('a dismissed alert is not badged', () async {
      // Badging a dismissed alert would defeat the dismissal while still
      // hiding the alert itself — the worst of both.
      await reportSoc(8);
      final alert = (await openAlert())!;
      await DismissAlert(
        repository: alerts,
        clock: h.clock,
      )(alert, DismissalReason.onIt);

      final rows = await fleet.fleetList(now: h.clock.nowUtc());
      expect(rows.first.openAlertCount, 0);
      expect(rows.first.hasCriticalAlert, isFalse);
    });
  });

  group('evaluation is idempotent', () {
    test('running the sweep twice changes nothing', () async {
      await reportSoc(8);
      final first = await alerts.openAlerts();

      final summary = await evaluate();

      expect(summary.opened, 0);
      expect(summary.resolved, 0);
      expect(await alerts.openAlerts(), first);
    });
  });

  group('battery temperature is a separate alert', () {
    test('both kinds can be open on one vehicle at once', () async {
      await h.ingestor.ingest([
        packet(
          packetId: 'both',
          eventTs: now.subtract(const Duration(seconds: 20)),
          signals: {SignalKind.soc: 8, SignalKind.batteryTemp: 50},
        ),
      ]);
      await evaluate();

      final open = await alerts.openAlerts();
      expect(open, hasLength(2));
      expect(
        open.map((a) => a.kind).toSet(),
        {AlertKind.batterySoc, AlertKind.batteryOverheating},
      );
    });
  });
}
