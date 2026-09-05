/// Alerts list, dismissal and undo — no database.
library;

import 'package:bloc_test/bloc_test.dart';
import 'package:fleet_console/core/clock.dart';
import 'package:fleet_console/domain/entities/alert.dart';
import 'package:fleet_console/domain/entities/signal_kind.dart';
import 'package:fleet_console/domain/entities/signal_reading.dart';
import 'package:fleet_console/domain/usecases/evaluate_alerts.dart';
import 'package:fleet_console/domain/usecases/manage_alerts.dart';
import 'package:fleet_console/presentation/alerts/bloc/alerts_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_alert_repository.dart';

void main() {
  late FakeAlertRepository repository;
  late FakeSnapshotSource snapshots;
  late FixedClock clock;
  final now = DateTime.utc(2026, 3, 1, 12);

  Alert alert(
    String vehicleId,
    AlertSeverity severity, {
    Duration openedAgo = const Duration(minutes: 5),
    AlertKind kind = AlertKind.batterySoc,
  }) => Alert(
    vehicleId: vehicleId,
    kind: kind,
    severity: severity,
    openedAt: now.subtract(openedAgo),
    lastKnownValue: severity == AlertSeverity.critical ? 8 : 18,
    lastKnownAt: now.subtract(const Duration(minutes: 1)),
  );

  /// Keeps the fleet quiet, so the evaluation sweep inside GetVisibleAlerts
  /// does not resolve the alerts the test just seeded.
  void keepConditionsFiring(Iterable<Alert> alerts) {
    snapshots.setSnapshots({
      for (final a in alerts)
        a.vehicleId: VehicleSnapshot(
          vehicleId: a.vehicleId,
          readings: {
            SignalKind.soc: SignalReading(
              kind: SignalKind.soc,
              value: a.severity == AlertSeverity.critical ? 8 : 18,
              eventTs: now.subtract(const Duration(minutes: 1)),
            ),
          },
        ),
    });
  }

  AlertsBloc build() {
    final evaluate = EvaluateAlerts(
      alerts: repository,
      snapshots: snapshots,
      clock: clock,
    );
    return AlertsBloc(
      getVisibleAlerts: GetVisibleAlerts(
        repository: repository,
        evaluate: evaluate,
      ),
      dismissAlert: DismissAlert(repository: repository, clock: clock),
      undoDismissal: UndoAlertDismissal(repository: repository, clock: clock),
    );
  }

  setUp(() {
    clock = FixedClock(now);
    snapshots = FakeSnapshotSource();
    repository = FakeAlertRepository();
  });

  group('loading', () {
    blocTest<AlertsBloc, AlertsState>(
      'sorts critical first, then oldest first',
      build: () {
        final seeded = [
          alert('V1', AlertSeverity.warning),
          alert('V2', AlertSeverity.critical, openedAgo: const Duration(minutes: 2)),
          alert('V3', AlertSeverity.critical, openedAgo: const Duration(hours: 1)),
        ];
        repository.setAlerts(seeded);
        keepConditionsFiring(seeded);
        return build();
      },
      act: (bloc) => bloc.add(const AlertsRequested()),
      verify: (bloc) {
        // An operator working down the list meets the worst problem first, and
        // among equals the one that has been waiting longest.
        expect(
          bloc.state.alerts.map((v) => v.alert.vehicleId).toList(),
          ['V3', 'V2', 'V1'],
        );
        expect(bloc.state.criticalCount, 2);
      },
    );

    blocTest<AlertsBloc, AlertsState>(
      'carries the registration, not the internal id',
      build: () {
        final seeded = [alert('V1', AlertSeverity.warning)];
        repository.setAlerts(seeded);
        keepConditionsFiring(seeded);
        return build();
      },
      act: (bloc) => bloc.add(const AlertsRequested()),
      verify: (bloc) => expect(bloc.state.alerts.first.regNumber, 'REG-V1'),
    );

    blocTest<AlertsBloc, AlertsState>(
      'a quiet fleet is empty, not an error',
      build: build,
      act: (bloc) => bloc.add(const AlertsRequested()),
      verify: (bloc) {
        expect(bloc.state.status, AlertsStatus.ready);
        expect(bloc.state.isEmpty, isTrue);
        expect(bloc.state.error, isNull);
      },
    );

    blocTest<AlertsBloc, AlertsState>(
      'surfaces a read failure',
      build: () {
        repository.failWith = StateError('database is locked');
        return build();
      },
      act: (bloc) => bloc.add(const AlertsRequested()),
      verify: (bloc) {
        expect(bloc.state.status, AlertsStatus.failed);
        expect(bloc.state.error, contains('database is locked'));
      },
    );
  });

  group('dismissal', () {
    blocTest<AlertsBloc, AlertsState>(
      'removes the alert immediately and offers undo',
      build: () {
        final seeded = [alert('V1', AlertSeverity.warning)];
        repository.setAlerts(seeded);
        keepConditionsFiring(seeded);
        return build();
      },
      act: (bloc) async {
        bloc.add(const AlertsRequested());
        await Future<void>.delayed(Duration.zero);
        bloc.add(
          AlertDismissed(bloc.state.alerts.first.alert, DismissalReason.onIt),
        );
      },
      verify: (bloc) {
        expect(bloc.state.alerts, isEmpty);
        expect(bloc.state.undoable, isNotNull);
        expect(bloc.state.undoable!.dismissalReason, DismissalReason.onIt);
        // Persisted at once rather than deferred: if the app dies mid-undo the
        // alert stays dismissed, which is what the user actually did.
        expect(repository.all.single.isDismissed, isTrue);
      },
    );

    blocTest<AlertsBloc, AlertsState>(
      'records the severity at dismissal, so escalation can override it',
      build: () {
        final seeded = [alert('V1', AlertSeverity.warning)];
        repository.setAlerts(seeded);
        keepConditionsFiring(seeded);
        return build();
      },
      act: (bloc) async {
        bloc.add(const AlertsRequested());
        await Future<void>.delayed(Duration.zero);
        bloc.add(
          AlertDismissed(bloc.state.alerts.first.alert, DismissalReason.onIt),
        );
      },
      verify: (bloc) => expect(
        repository.all.single.dismissedAtSeverity,
        AlertSeverity.warning,
      ),
    );
  });

  group('undo', () {
    blocTest<AlertsBloc, AlertsState>(
      'restores the alert inside the window',
      build: () {
        final seeded = [alert('V1', AlertSeverity.warning)];
        repository.setAlerts(seeded);
        keepConditionsFiring(seeded);
        return build();
      },
      act: (bloc) async {
        bloc.add(const AlertsRequested());
        await Future<void>.delayed(Duration.zero);
        bloc.add(
          AlertDismissed(bloc.state.alerts.first.alert, DismissalReason.onIt),
        );
        await Future<void>.delayed(Duration.zero);
        clock.advance(const Duration(seconds: 2));
        bloc.add(const AlertDismissalUndone());
      },
      wait: const Duration(milliseconds: 50),
      verify: (bloc) {
        expect(bloc.state.alerts, hasLength(1));
        expect(bloc.state.undoable, isNull);
        expect(repository.all.single.isDismissed, isFalse);
      },
    );

    blocTest<AlertsBloc, AlertsState>(
      'refuses after the window and leaves it dismissed',
      build: () {
        final seeded = [alert('V1', AlertSeverity.warning)];
        repository.setAlerts(seeded);
        keepConditionsFiring(seeded);
        return build();
      },
      act: (bloc) async {
        bloc.add(const AlertsRequested());
        await Future<void>.delayed(Duration.zero);
        bloc.add(
          AlertDismissed(bloc.state.alerts.first.alert, DismissalReason.onIt),
        );
        await Future<void>.delayed(Duration.zero);
        // A snackbar still on screen because the device slept is not a licence
        // to rewrite a decision made a minute ago.
        clock.advance(const Duration(minutes: 1));
        bloc.add(const AlertDismissalUndone());
      },
      wait: const Duration(milliseconds: 50),
      verify: (bloc) {
        expect(bloc.state.alerts, isEmpty);
        expect(repository.all.single.isDismissed, isTrue);
      },
    );

    blocTest<AlertsBloc, AlertsState>(
      'undo with nothing to undo is a no-op',
      build: build,
      act: (bloc) => bloc.add(const AlertDismissalUndone()),
      expect: () => <AlertsState>[],
    );
  });
}
