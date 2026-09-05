/// The status chip, including the cases the brief's table leaves open.
library;

import 'package:fleet_console/domain/entities/signal_kind.dart';
import 'package:fleet_console/domain/entities/signal_reading.dart';
import 'package:fleet_console/domain/entities/vehicle_status.dart';
import 'package:fleet_console/domain/rules/status_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 3, 1, 12);

  VehicleSnapshot snapshot(Map<SignalKind, (double, Duration)> signals) =>
      VehicleSnapshot(
        vehicleId: 'V1',
        readings: {
          for (final entry in signals.entries)
            entry.key: SignalReading(
              kind: entry.key,
              value: entry.value.$1,
              eventTs: now.subtract(entry.value.$2),
            ),
        },
      );

  const fresh = Duration(minutes: 1);
  const stale = Duration(minutes: 30);

  group('first match wins, in the brief order', () {
    test('OFFLINE beats everything, even a fresh-looking speed', () {
      // Every reading is old, so the vehicle-level ping is old.
      final v = snapshot({
        SignalKind.speed: (60, stale),
        SignalKind.ignition: (1, stale),
      });
      expect(statusOf(v, now), VehicleStatus.offline);
    });

    test('MOVING when speed is above zero', () {
      final v = snapshot({
        SignalKind.speed: (42, fresh),
        SignalKind.ignition: (1, fresh),
      });
      expect(statusOf(v, now), VehicleStatus.moving);
    });

    test('MOVING beats IDLE and STOPPED', () {
      // Contradictory data: moving with the ignition reported off. Speed wins,
      // because it is checked first.
      final v = snapshot({
        SignalKind.speed: (42, fresh),
        SignalKind.ignition: (0, fresh),
      });
      expect(statusOf(v, now), VehicleStatus.moving);
    });

    test('IDLE when stationary with the ignition on', () {
      final v = snapshot({
        SignalKind.speed: (0, fresh),
        SignalKind.ignition: (1, fresh),
      });
      expect(statusOf(v, now), VehicleStatus.idle);
    });

    test('STOPPED when the ignition is off', () {
      final v = snapshot({
        SignalKind.speed: (0, fresh),
        SignalKind.ignition: (0, fresh),
      });
      expect(statusOf(v, now), VehicleStatus.stopped);
    });
  });

  group('offline boundary', () {
    test('exactly at the threshold is still online', () {
      final v = snapshot({SignalKind.speed: (0, const Duration(minutes: 10))});
      expect(statusOf(v, now), isNot(VehicleStatus.offline));
    });

    test('one second past the threshold is offline', () {
      final v = snapshot({
        SignalKind.speed: (0, const Duration(minutes: 10, seconds: 1)),
      });
      expect(statusOf(v, now), VehicleStatus.offline);
    });

    test('a vehicle that has never reported is offline', () {
      const v = VehicleSnapshot(vehicleId: 'V1', readings: {});
      expect(statusOf(v, now), VehicleStatus.offline);
    });

    test('freshness is vehicle-level: any fresh signal keeps it online', () {
      // Only the odometer is fresh. That is still a ping.
      final v = snapshot({
        SignalKind.odometer: (120000, fresh),
        SignalKind.speed: (55, stale),
      });
      expect(statusOf(v, now), isNot(VehicleStatus.offline));
    });
  });

  group('stale readings do not classify', () {
    // This is the rule that keeps the status chip consistent with the verdict
    // pill on the vehicle detail screen, which shows the same reading as STALE
    // and explicitly makes no claim about it.
    test('an online vehicle with only a stale speed is UNKNOWN, not MOVING',
        () {
      final v = snapshot({
        SignalKind.odometer: (120000, fresh),
        SignalKind.speed: (55, stale),
      });
      expect(statusOf(v, now), VehicleStatus.unknown);
    });

    test('a stale ignition-off does not make it STOPPED', () {
      final v = snapshot({
        SignalKind.odometer: (120000, fresh),
        SignalKind.ignition: (0, stale),
      });
      expect(statusOf(v, now), VehicleStatus.unknown);
    });

    test('fresh zero speed with a stale ignition is UNKNOWN, not IDLE', () {
      // We know it is not moving, but IDLE asserts the ignition is on and
      // STOPPED asserts it is off. Neither is supportable.
      final v = snapshot({
        SignalKind.speed: (0, fresh),
        SignalKind.ignition: (1, stale),
      });
      expect(statusOf(v, now), VehicleStatus.unknown);
    });
  });

  group('online but unclassifiable', () {
    test('a vehicle reporting only an odometer is UNKNOWN', () {
      final v = snapshot({SignalKind.odometer: (98000, fresh)});
      expect(statusOf(v, now), VehicleStatus.unknown);
    });

    test('UNKNOWN has no filter chip of its own', () {
      expect(VehicleStatus.unknown.hasFilterChip, isFalse);
      for (final status in VehicleStatus.values) {
        if (status != VehicleStatus.unknown) {
          expect(status.hasFilterChip, isTrue, reason: '$status');
        }
      }
    });
  });
}
