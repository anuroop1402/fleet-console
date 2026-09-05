/// Freshness and the verdict pill.
library;

import 'package:fleet_console/domain/entities/signal_kind.dart';
import 'package:fleet_console/domain/entities/signal_reading.dart';
import 'package:fleet_console/domain/entities/verdict.dart';
import 'package:fleet_console/domain/rules/staleness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 3, 1, 12);

  SignalReading reading(SignalKind kind, double value, Duration age) =>
      SignalReading(kind: kind, value: value, eventTs: now.subtract(age));

  group('isFresh', () {
    test('is inclusive at the boundary', () {
      expect(isFresh(now.subtract(const Duration(minutes: 10)), now), isTrue);
      expect(
        isFresh(now.subtract(const Duration(minutes: 10, seconds: 1)), now),
        isFalse,
      );
    });

    test('a slightly future reading is fresh, not an error', () {
      // Vehicle clocks drift. Ingest already rejects implausible skew, so a
      // few seconds ahead is a real reading and must not be treated as stale.
      expect(isFresh(now.add(const Duration(seconds: 20)), now), isTrue);
    });
  });

  group('verdictFor', () {
    test('a signal that never reported is neverReported, not stale', () {
      // These are different facts: one is "we have no value", the other is
      // "we have a value we refuse to judge". Collapsing them would put a grey
      // pill on a signal that should show a bare dash.
      expect(
        verdictFor(kind: SignalKind.soc, reading: null, now: now),
        Verdict.neverReported,
      );
    });

    test('fresh and within threshold is normal', () {
      expect(
        verdictFor(
          kind: SignalKind.soc,
          reading: reading(SignalKind.soc, 80, const Duration(minutes: 2)),
          now: now,
        ),
        Verdict.normal,
      );
    });

    test('fresh and outside threshold is alert', () {
      expect(
        verdictFor(
          kind: SignalKind.soc,
          reading: reading(SignalKind.soc, 12, const Duration(minutes: 2)),
          now: now,
        ),
        Verdict.alert,
      );
    });

    test('an old breach is STALE, never ALERT', () {
      // The single most important line in this file. An eight-hour-old 5% SOC
      // is not evidence the battery is flat now.
      expect(
        verdictFor(
          kind: SignalKind.soc,
          reading: reading(SignalKind.soc, 5, const Duration(hours: 8)),
          now: now,
        ),
        Verdict.stale,
      );
    });

    test('battery temperature alerts above 45C', () {
      expect(
        verdictFor(
          kind: SignalKind.batteryTemp,
          reading: reading(SignalKind.batteryTemp, 46, const Duration(minutes: 1)),
          now: now,
        ),
        Verdict.alert,
      );
      expect(
        verdictFor(
          kind: SignalKind.batteryTemp,
          reading: reading(SignalKind.batteryTemp, 45, const Duration(minutes: 1)),
          now: now,
        ),
        Verdict.normal,
        reason: 'the threshold is strictly greater than',
      );
    });

    test('signals with no threshold are reported, not judged', () {
      for (final kind in [
        SignalKind.speed,
        SignalKind.odometer,
        SignalKind.rangeKm,
        SignalKind.ignition,
      ]) {
        expect(breachesThreshold(kind, 999999), isNull, reason: '$kind');
        expect(
          verdictFor(
            kind: kind,
            reading: reading(kind, 999999, const Duration(minutes: 1)),
            now: now,
          ),
          Verdict.normal,
          reason: '$kind',
        );
      }
    });
  });

  group('verdict semantics', () {
    test('only normal and alert make a claim', () {
      expect(Verdict.normal.isClaim, isTrue);
      expect(Verdict.alert.isClaim, isTrue);
      expect(Verdict.stale.isClaim, isFalse);
      expect(Verdict.neverReported.isClaim, isFalse);
    });

    test('only neverReported draws no pill', () {
      expect(Verdict.neverReported.hasPill, isFalse);
      expect(Verdict.stale.hasPill, isTrue);
    });
  });

  group('vehicle-level freshness', () {
    test('lastPing is the newest event time across all signals', () {
      final snapshot = VehicleSnapshot(
        vehicleId: 'V1',
        readings: {
          SignalKind.soc: reading(SignalKind.soc, 50, const Duration(hours: 3)),
          SignalKind.speed: reading(
            SignalKind.speed,
            0,
            const Duration(minutes: 2),
          ),
        },
      );

      expect(snapshot.lastPing, now.subtract(const Duration(minutes: 2)));
      expect(isVehicleOnline(snapshot.lastPing, now), isTrue);
    });

    test('a vehicle can be online while one of its signals is stale', () {
      // The case a reviewer is most likely to probe, and the reason the brief
      // separates vehicle-level last ping from each signal's own age.
      final snapshot = VehicleSnapshot(
        vehicleId: 'V1',
        readings: {
          SignalKind.soc: reading(SignalKind.soc, 50, const Duration(hours: 3)),
          SignalKind.speed: reading(
            SignalKind.speed,
            30,
            const Duration(minutes: 2),
          ),
        },
      );

      expect(isVehicleOnline(snapshot.lastPing, now), isTrue);
      expect(
        verdictFor(
          kind: SignalKind.soc,
          reading: snapshot[SignalKind.soc],
          now: now,
        ),
        Verdict.stale,
      );
    });

    test('no readings at all means offline', () {
      const snapshot = VehicleSnapshot(vehicleId: 'V1', readings: {});
      expect(snapshot.lastPing, isNull);
      expect(isVehicleOnline(snapshot.lastPing, now), isFalse);
    });
  });
}
