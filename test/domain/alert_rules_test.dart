/// The alert state machine, including the four cases the brief leaves open.
///
/// Each group here maps to a row of the table in docs/01 §3. If one fails, a
/// documented resolution has silently stopped being true.
library;

import 'package:fleet_console/domain/entities/alert.dart';
import 'package:fleet_console/domain/entities/signal_kind.dart';
import 'package:fleet_console/domain/entities/signal_reading.dart';
import 'package:fleet_console/domain/rules/alert_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 3, 1, 12);

  VehicleSnapshot withSoc(double soc, {Duration age = const Duration(minutes: 1)}) =>
      VehicleSnapshot(
        vehicleId: 'V1',
        readings: {
          SignalKind.soc: SignalReading(
            kind: SignalKind.soc,
            value: soc,
            eventTs: now.subtract(age),
          ),
        },
      );

  AlertEvaluation step(Alert? current, VehicleSnapshot snapshot) =>
      evaluateAlert(
        current: current,
        observation: observeSoc(snapshot, now),
        kind: AlertKind.batterySoc,
        vehicleId: 'V1',
        now: now,
      );

  group('observing the SOC condition', () {
    test('above 20% is clear', () {
      expect(observeSoc(withSoc(35), now), isA<ConditionClear>());
    });

    test('below 20% fires at warning', () {
      final o = observeSoc(withSoc(18), now) as ConditionFiring;
      expect(o.severity, AlertSeverity.warning);
    });

    test('below 10% fires at critical', () {
      final o = observeSoc(withSoc(8), now) as ConditionFiring;
      expect(o.severity, AlertSeverity.critical);
    });

    test('exactly 20% is clear — the threshold is strictly less than', () {
      expect(observeSoc(withSoc(20), now), isA<ConditionClear>());
    });

    test('a stale reading is unobservable, never clear', () {
      // The distinction the whole type exists for. A stale 8% must not be read
      // as "the battery recovered".
      final o = observeSoc(withSoc(8, age: const Duration(hours: 2)), now);
      expect(o, isA<ConditionUnobservable>());
      expect((o as ConditionUnobservable).lastKnownValue, 8);
    });

    test('a signal that never reported is unobservable', () {
      const empty = VehicleSnapshot(vehicleId: 'V1', readings: {});
      final o = observeSoc(empty, now);
      expect(o, isA<ConditionUnobservable>());
      expect((o as ConditionUnobservable).lastKnownValue, isNull);
    });
  });

  group('one escalating alert, not two', () {
    test('SOC falling from warning to critical keeps the same instance', () {
      final opened = step(null, withSoc(18)).alert!;
      expect(opened.severity, AlertSeverity.warning);

      final escalated = step(opened, withSoc(8));
      expect(escalated.transition, AlertTransition.escalated);
      expect(escalated.alert!.severity, AlertSeverity.critical);
      expect(
        escalated.alert!.openedAt,
        opened.openedAt,
        reason: 'the same instance escalated; it is not a second alert',
      );
    });

    test('recovering from critical to warning de-escalates in place', () {
      final critical = step(null, withSoc(8)).alert!;
      final back = step(critical, withSoc(15));

      expect(back.transition, AlertTransition.deEscalated);
      expect(back.alert!.severity, AlertSeverity.warning);
      expect(back.alert!.openedAt, critical.openedAt);
    });
  });

  group('case 1 — dismissed at warning, then escalates', () {
    test('the alert reappears at critical', () {
      // Silencing a warning is not consent to silence a critical.
      final warning = step(null, withSoc(18)).alert!;
      final dismissed = dismiss(warning, DismissalReason.onIt, now);
      expect(dismissed.isVisible, isFalse);

      final escalated = step(dismissed, withSoc(8));

      expect(escalated.alert!.severity, AlertSeverity.critical);
      expect(escalated.alert!.isDismissed, isFalse);
      expect(escalated.alert!.isVisible, isTrue);
    });

    test('but a dismissed warning staying at warning stays hidden', () {
      final warning = step(null, withSoc(18)).alert!;
      final dismissed = dismiss(warning, DismissalReason.onIt, now);

      final still = step(dismissed, withSoc(16));

      expect(still.alert!.isDismissed, isTrue);
      expect(still.alert!.isVisible, isFalse);
    });
  });

  group('case 2 — dismissed at critical, then recovers to warning', () {
    test('severity drops but the dismissal holds', () {
      // The human said "I am on it" about a battery problem that still exists.
      final critical = step(null, withSoc(8)).alert!;
      final dismissed = dismiss(critical, DismissalReason.onIt, now);

      final recovered = step(dismissed, withSoc(15));

      expect(recovered.alert!.severity, AlertSeverity.warning);
      expect(recovered.alert!.isDismissed, isTrue);
      expect(recovered.alert!.isVisible, isFalse);
    });
  });

  group('case 3 — a cleared condition resolves, independently of dismissal', () {
    test('recovering above 20% resolves an open alert', () {
      final warning = step(null, withSoc(18)).alert!;
      final resolved = step(warning, withSoc(45));

      expect(resolved.transition, AlertTransition.resolved);
      expect(resolved.alert, isNull);
    });

    test('recovering resolves a dismissed alert too', () {
      final warning = step(null, withSoc(18)).alert!;
      final dismissed = dismiss(warning, DismissalReason.onIt, now);

      final resolved = step(dismissed, withSoc(45));

      expect(resolved.transition, AlertTransition.resolved);
      expect(resolved.alert, isNull);
    });

    test('re-firing after a resolve opens a NEW instance, not the old one', () {
      final first = step(null, withSoc(18)).alert!;
      final dismissed = dismiss(first, DismissalReason.onIt, now);
      expect(step(dismissed, withSoc(45)).alert, isNull);

      // Later, it drops again.
      final laterNow = now.add(const Duration(hours: 4));
      final refired = evaluateAlert(
        current: null,
        observation: observeSoc(
          VehicleSnapshot(
            vehicleId: 'V1',
            readings: {
              SignalKind.soc: SignalReading(
                kind: SignalKind.soc,
                value: 17,
                eventTs: laterNow.subtract(const Duration(minutes: 1)),
              ),
            },
          ),
          laterNow,
        ),
        kind: AlertKind.batterySoc,
        vehicleId: 'V1',
        now: laterNow,
      );

      expect(refired.transition, AlertTransition.opened);
      expect(
        refired.alert!.isDismissed,
        isFalse,
        reason: 'a new occurrence deserves a fresh decision',
      );
      expect(refired.alert!.openedAt.isAfter(first.openedAt), isTrue);
    });
  });

  group('case 4 — the reading goes stale while the alert is open', () {
    test('the alert stays open and is flagged, not resolved', () {
      // Resolving would assert the condition cleared. We cannot see that.
      final critical = step(null, withSoc(8)).alert!;

      final stale = step(critical, withSoc(8, age: const Duration(hours: 2)));

      expect(stale.transition, AlertTransition.markedStale);
      expect(stale.alert, isNotNull);
      expect(stale.alert!.isConditionStale, isTrue);
      expect(stale.alert!.severity, AlertSeverity.critical);
    });

    test('it remembers the last known value and when it was seen', () {
      final critical = step(null, withSoc(8)).alert!;
      final stale = step(critical, withSoc(8, age: const Duration(hours: 2)));

      expect(stale.alert!.lastKnownValue, 8);
      expect(
        stale.alert!.lastKnownAt,
        now.subtract(const Duration(hours: 2)),
      );
    });

    test('going stale twice reports unchanged, not repeatedly marked', () {
      final critical = step(null, withSoc(8)).alert!;
      final once = step(critical, withSoc(8, age: const Duration(hours: 2)));
      final twice = step(
        once.alert,
        withSoc(8, age: const Duration(hours: 3)),
      );

      expect(twice.transition, AlertTransition.unchanged);
      expect(twice.alert!.isConditionStale, isTrue);
    });

    test('becoming observable again clears the stale flag', () {
      final critical = step(null, withSoc(8)).alert!;
      final stale = step(critical, withSoc(8, age: const Duration(hours: 2)));

      final visibleAgain = step(stale.alert, withSoc(8));

      expect(visibleAgain.alert!.isConditionStale, isFalse);
    });

    test('nothing open and nothing observable stays silent', () {
      const empty = VehicleSnapshot(vehicleId: 'V1', readings: {});
      final result = step(null, empty);

      expect(result.transition, AlertTransition.none);
      expect(result.alert, isNull);
    });
  });

  group('battery overheating', () {
    VehicleSnapshot withTemp(double c, {Duration age = const Duration(minutes: 1)}) =>
        VehicleSnapshot(
          vehicleId: 'V1',
          readings: {
            SignalKind.batteryTemp: SignalReading(
              kind: SignalKind.batteryTemp,
              value: c,
              eventTs: now.subtract(age),
            ),
          },
        );

    test('fires critical above 45C', () {
      final o = observeBatteryTemperature(withTemp(47), now) as ConditionFiring;
      expect(o.severity, AlertSeverity.critical);
    });

    test('is clear at exactly 45C', () {
      expect(
        observeBatteryTemperature(withTemp(45), now),
        isA<ConditionClear>(),
      );
    });

    test('is a separate kind from the SOC alert', () {
      final temp = evaluateAlert(
        current: null,
        observation: observeBatteryTemperature(withTemp(50), now),
        kind: AlertKind.batteryOverheating,
        vehicleId: 'V1',
        now: now,
      );
      expect(temp.alert!.kind, AlertKind.batteryOverheating);
    });
  });

  group('dismissal and undo', () {
    test('dismissal records the reason and the severity at the time', () {
      final warning = step(null, withSoc(18)).alert!;
      final dismissed = dismiss(warning, DismissalReason.wrongAlert, now);

      expect(dismissed.dismissalReason, DismissalReason.wrongAlert);
      expect(dismissed.dismissedAtSeverity, AlertSeverity.warning);
      expect(dismissed.dismissedAt, now);
    });

    test('undo restores visibility', () {
      final warning = step(null, withSoc(18)).alert!;
      final dismissed = dismiss(warning, DismissalReason.onIt, now);

      final restored = undoDismissal(dismissed);

      expect(restored.isDismissed, isFalse);
      expect(restored.isVisible, isTrue);
      expect(restored.openedAt, warning.openedAt);
    });

    test('undo is available for five seconds and no longer', () {
      final warning = step(null, withSoc(18)).alert!;
      final dismissed = dismiss(warning, DismissalReason.onIt, now);

      expect(canUndo(dismissed, now.add(const Duration(seconds: 4))), isTrue);
      expect(canUndo(dismissed, now.add(const Duration(seconds: 5))), isTrue);
      expect(
        canUndo(dismissed, now.add(const Duration(seconds: 6))),
        isFalse,
      );
    });

    test('an alert that was never dismissed cannot be undone', () {
      final warning = step(null, withSoc(18)).alert!;
      expect(canUndo(warning, now), isFalse);
    });

    test('the three reasons are in the order the brief specifies', () {
      expect(DismissalReason.values.map((r) => r.label).toList(), [
        'I am on it',
        'Wrong alert',
        'Something else…',
      ]);
    });
  });
}
