/// The use case that turns raw readings into a readings register.
library;

import 'package:fleet_console/core/clock.dart';
import 'package:fleet_console/core/constants.dart';
import 'package:fleet_console/domain/entities/fleet_view.dart';
import 'package:fleet_console/domain/entities/signal_kind.dart';
import 'package:fleet_console/domain/entities/signal_reading.dart';
import 'package:fleet_console/domain/entities/vehicle_status.dart';
import 'package:fleet_console/domain/entities/verdict.dart';
import 'package:fleet_console/domain/usecases/get_vehicle_detail.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_fleet_repository.dart';

void main() {
  late FakeFleetRepository repository;
  late FixedClock clock;
  late GetVehicleDetail useCase;
  final now = DateTime.utc(2026, 3, 1, 12);

  setUp(() {
    clock = FixedClock(now);
    repository = FakeFleetRepository();
    useCase = GetVehicleDetail(repository: repository, clock: clock);
  });

  void give(Map<SignalKind, (double, Duration)> signals) {
    repository.setReadings(
      'V1',
      VehicleReadings(
        vehicle: const Vehicle(
          vehicleId: 'V1',
          regNumber: 'KA01AB1234',
          model: 'Tata Ace EV',
        ),
        snapshot: VehicleSnapshot(
          vehicleId: 'V1',
          readings: {
            for (final entry in signals.entries)
              entry.key: SignalReading(
                kind: entry.key,
                value: entry.value.$1,
                eventTs: now.subtract(entry.value.$2),
              ),
          },
        ),
      ),
    );
  }

  test('an unknown vehicle returns null, not an empty detail', () async {
    expect(await useCase('nope'), isNull);
  });

  test('the register always has every signal, in a fixed order', () async {
    // Only SOC has reported, but the register must still show all six rows —
    // otherwise the screen reshuffles as packets arrive.
    give({SignalKind.soc: (55, const Duration(minutes: 1))});

    final detail = await useCase('V1');

    expect(
      detail!.register.map((r) => r.kind).toList(),
      GetVehicleDetail.registerOrder,
    );
    expect(detail.register, hasLength(SignalKind.values.length));
  });

  test('a signal that never reported has no value and no pill', () async {
    give({SignalKind.soc: (55, const Duration(minutes: 1))});

    final detail = await useCase('V1');
    final odometer = detail!.register.firstWhere(
      (r) => r.kind == SignalKind.odometer,
    );

    expect(odometer.verdict, Verdict.neverReported);
    expect(odometer.value, isNull);
    expect(odometer.age, isNull);
    expect(odometer.verdict.hasPill, isFalse);
  });

  test('each row carries its own age', () async {
    give({
      SignalKind.soc: (55, const Duration(minutes: 2)),
      SignalKind.speed: (40, const Duration(minutes: 7)),
    });

    final detail = await useCase('V1');
    final soc = detail!.register.firstWhere((r) => r.kind == SignalKind.soc);
    final speed = detail.register.firstWhere(
      (r) => r.kind == SignalKind.speed,
    );

    expect(soc.age, const Duration(minutes: 2));
    expect(speed.age, const Duration(minutes: 7));
  });

  test('a MOVING vehicle can have a STALE SOC pill', () async {
    // The combination the brief most invites a reviewer to probe, and the
    // reason vehicle-level freshness and per-signal age are kept separate.
    give({
      SignalKind.speed: (45, const Duration(minutes: 1)),
      SignalKind.ignition: (1, const Duration(minutes: 1)),
      SignalKind.soc: (8, const Duration(hours: 3)),
    });

    final detail = await useCase('V1');
    final soc = detail!.register.firstWhere((r) => r.kind == SignalKind.soc);

    expect(detail.status, VehicleStatus.moving);
    expect(soc.verdict, Verdict.stale);
    expect(
      soc.verdict.isClaim,
      isFalse,
      reason: 'a three-hour-old 8% is not evidence the battery is flat now',
    );
  });

  test('a fresh breach is ALERT, an old one is STALE', () async {
    give({SignalKind.soc: (8, const Duration(minutes: 1))});
    var detail = await useCase('V1');
    expect(
      detail!.register.firstWhere((r) => r.kind == SignalKind.soc).verdict,
      Verdict.alert,
    );

    give({SignalKind.soc: (8, const Duration(hours: 1))});
    detail = await useCase('V1');
    expect(
      detail!.register.firstWhere((r) => r.kind == SignalKind.soc).verdict,
      Verdict.stale,
    );
  });

  test('every row is judged against the same instant', () async {
    // Two signals of identical age must never disagree about staleness because
    // the clock ticked between them.
    final boundary = FleetThresholds.signalStaleAfter;
    give({
      SignalKind.soc: (50, boundary),
      SignalKind.speed: (0, boundary),
      SignalKind.rangeKm: (100, boundary),
    });

    final detail = await useCase('V1');
    final verdicts = detail!.register
        .where((r) => r.age == boundary)
        .map((r) => r.verdict)
        .toSet();

    expect(verdicts, hasLength(1));
  });

  group('SOC history', () {
    test('asks for exactly the retained window', () async {
      final history = GetSocHistory(repository: repository, clock: clock);
      await history('V1');

      expect(
        repository.lastHistorySince,
        now.subtract(RetentionPolicy.rawSignals),
        reason: 'past retention the raw readings are rolled up, so asking for '
            'them would draw a misleadingly sparse line',
      );
    });

    test('passes the point cap through', () async {
      final history = GetSocHistory(repository: repository, clock: clock);
      await history('V1', maxPoints: 42);
      expect(repository.lastHistoryMaxPoints, 42);
    });
  });
}
