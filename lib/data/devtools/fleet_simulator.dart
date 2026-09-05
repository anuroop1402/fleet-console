/// A deterministic fake fleet, for development and for the scale exercise.
///
/// Stands in for a real MQTT feed. That is a deliberate cut, recorded in
/// docs/01 §4: a broker would prove plumbing, whereas the properties actually
/// under test — late, duplicated and out-of-order arrival, backlog dumps,
/// vehicles that go quiet — are far easier to produce on purpose than to wait
/// for. Every awkward case the UI must handle is generated here on demand.
library;

import 'dart:math';

import '../../core/clock.dart';
import '../../domain/entities/fleet_view.dart';
import '../../domain/entities/signal_kind.dart';
import '../../domain/entities/telemetry_packet.dart';

/// The behaviour a simulated vehicle exhibits.
///
/// Named rather than random, so "show me a moving truck whose SOC is stale"
/// is a thing that can be asked for instead of waited for.
enum VehicleProfile {
  /// Driving, healthy battery.
  moving,

  /// Stationary, ignition on.
  idling,

  /// Parked, ignition off.
  parked,

  /// Silent for hours. Renders OFFLINE.
  inBasement,

  /// Driving, but SOC below 20%. Raises a warning.
  lowBattery,

  /// Driving, SOC below 10%. Raises a critical.
  criticallyLow,

  /// Battery above 45 C. Raises a critical.
  overheating,

  /// Online — odometer is fresh — but speed and ignition are hours old.
  /// Renders UNKNOWN, and its SOC pill reads STALE while the vehicle is not
  /// offline. This is the combination worth looking at on a real screen.
  partiallyReporting,

  /// Registered but has never sent a packet. Every pill reads "—".
  neverReported;

  /// Roughly how a real fleet is distributed, for the bulk generator.
  static const List<VehicleProfile> weighted = [
    moving, moving, moving, moving, moving,
    idling, idling,
    parked, parked, parked,
    inBasement,
    lowBattery,
    criticallyLow,
    overheating,
    partiallyReporting,
  ];
}

/// Generates packets. Pure apart from the clock — given the same seed and the
/// same instant it produces byte-identical output, which is what makes the
/// scale numbers in docs/05 reproducible.
final class FleetSimulator {
  FleetSimulator({required Clock clock, int seed = 20260301})
    : _clock = clock,
      _random = Random(seed);

  final Clock _clock;
  final Random _random;

  static const List<String> _models = [
    'Tata Ace EV',
    'Ashok Leyland Dost EV',
    'Mahindra Zeo',
    'Eicher Pro 2049',
    'BYD ETH8',
  ];

  /// A fleet register of [count] vehicles with stable, readable identities.
  List<Vehicle> vehicles(int count) => [
    for (var i = 0; i < count; i++)
      Vehicle(
        vehicleId: 'VH${i.toString().padLeft(4, '0')}',
        regNumber: 'KA${(1 + i % 60).toString().padLeft(2, '0')}'
            '${_letters(i)}${(1000 + i % 9000).toString()}',
        model: _models[i % _models.length],
      ),
  ];

  /// The profile assigned to a vehicle. Deterministic from its index, so the
  /// same vehicle always behaves the same way across restarts.
  VehicleProfile profileFor(int index) =>
      VehicleProfile.weighted[index % VehicleProfile.weighted.length];

  /// One round of telemetry for the whole fleet, as of now.
  List<TelemetryPacket> currentRound(List<Vehicle> fleet) {
    final now = _clock.nowUtc();
    final packets = <TelemetryPacket>[];

    for (var i = 0; i < fleet.length; i++) {
      final profile = profileFor(i);
      if (profile == VehicleProfile.neverReported) continue;

      packets.addAll(_packetsFor(fleet[i], profile, i, now));
    }
    return packets;
  }

  List<TelemetryPacket> _packetsFor(
    Vehicle vehicle,
    VehicleProfile profile,
    int index,
    DateTime now,
  ) {
    final odometer = 40000 + (index * 137) % 90000;

    // Ages chosen to land either side of the ten-minute freshness threshold on
    // purpose, so the UI has to render both cases.
    TelemetryPacket build(
      Duration age,
      Map<SignalKind, double> signals, {
      String suffix = '',
    }) {
      final eventTs = now.subtract(age);
      return TelemetryPacket(
        packetId: '${vehicle.vehicleId}-${eventTs.microsecondsSinceEpoch}$suffix',
        vehicleId: vehicle.vehicleId,
        eventTs: eventTs,
        signals: signals,
      );
    }

    final jitter = Duration(seconds: _random.nextInt(90));

    return switch (profile) {
      VehicleProfile.moving => [
        build(jitter, {
          SignalKind.speed: 20 + _random.nextInt(50).toDouble(),
          SignalKind.ignition: 1,
          SignalKind.soc: 45 + _random.nextInt(50).toDouble(),
          SignalKind.rangeKm: 120 + _random.nextInt(180).toDouble(),
          SignalKind.batteryTemp: 28 + _random.nextInt(10).toDouble(),
          SignalKind.odometer: odometer.toDouble(),
        }),
      ],
      VehicleProfile.idling => [
        build(jitter, {
          SignalKind.speed: 0,
          SignalKind.ignition: 1,
          SignalKind.soc: 50 + _random.nextInt(40).toDouble(),
          SignalKind.rangeKm: 150 + _random.nextInt(150).toDouble(),
          SignalKind.batteryTemp: 26 + _random.nextInt(8).toDouble(),
          SignalKind.odometer: odometer.toDouble(),
        }),
      ],
      VehicleProfile.parked => [
        build(jitter, {
          SignalKind.speed: 0,
          SignalKind.ignition: 0,
          SignalKind.soc: 60 + _random.nextInt(35).toDouble(),
          SignalKind.rangeKm: 180 + _random.nextInt(120).toDouble(),
          SignalKind.batteryTemp: 24 + _random.nextInt(6).toDouble(),
          SignalKind.odometer: odometer.toDouble(),
        }),
      ],
      VehicleProfile.inBasement => [
        // Last heard from hours ago. Everything is old, so it reads OFFLINE.
        build(Duration(hours: 2 + _random.nextInt(6)), {
          SignalKind.speed: 0,
          SignalKind.ignition: 0,
          SignalKind.soc: 30 + _random.nextInt(40).toDouble(),
          SignalKind.rangeKm: 90 + _random.nextInt(120).toDouble(),
          SignalKind.odometer: odometer.toDouble(),
        }),
      ],
      VehicleProfile.lowBattery => [
        build(jitter, {
          SignalKind.speed: 15 + _random.nextInt(35).toDouble(),
          SignalKind.ignition: 1,
          SignalKind.soc: 11 + _random.nextInt(8).toDouble(),
          SignalKind.rangeKm: 15 + _random.nextInt(25).toDouble(),
          SignalKind.batteryTemp: 30 + _random.nextInt(8).toDouble(),
          SignalKind.odometer: odometer.toDouble(),
        }),
      ],
      VehicleProfile.criticallyLow => [
        build(jitter, {
          SignalKind.speed: 5 + _random.nextInt(20).toDouble(),
          SignalKind.ignition: 1,
          SignalKind.soc: 3 + _random.nextInt(6).toDouble(),
          SignalKind.rangeKm: 2 + _random.nextInt(10).toDouble(),
          SignalKind.batteryTemp: 32 + _random.nextInt(8).toDouble(),
          SignalKind.odometer: odometer.toDouble(),
        }),
      ],
      VehicleProfile.overheating => [
        build(jitter, {
          SignalKind.speed: 30 + _random.nextInt(40).toDouble(),
          SignalKind.ignition: 1,
          SignalKind.soc: 40 + _random.nextInt(40).toDouble(),
          SignalKind.rangeKm: 100 + _random.nextInt(120).toDouble(),
          SignalKind.batteryTemp: 46 + _random.nextInt(9).toDouble(),
          SignalKind.odometer: odometer.toDouble(),
        }),
      ],
      VehicleProfile.partiallyReporting => [
        // Fresh odometer keeps it online...
        build(jitter, {SignalKind.odometer: odometer.toDouble()}),
        // ...while everything that could classify it, or judge its battery,
        // is hours old. Status reads UNKNOWN and the SOC pill reads STALE.
        build(
          Duration(hours: 3 + _random.nextInt(4)),
          {
            SignalKind.speed: 40,
            SignalKind.ignition: 1,
            SignalKind.soc: 8 + _random.nextInt(10).toDouble(),
            SignalKind.rangeKm: 20 + _random.nextInt(40).toDouble(),
          },
          suffix: '-old',
        ),
      ],
      VehicleProfile.neverReported => const [],
    };
  }

  /// Awkward arrivals, on demand: a duplicate, a late packet carrying an older
  /// reading, and a backlog dump.
  ///
  /// Used by tests and by the debug menu to prove the ingest guarantees against
  /// a running app rather than only in a unit test.
  List<TelemetryPacket> adversarialRound(Vehicle vehicle) {
    final now = _clock.nowUtc();

    final original = TelemetryPacket(
      packetId: '${vehicle.vehicleId}-dup',
      vehicleId: vehicle.vehicleId,
      eventTs: now.subtract(const Duration(minutes: 1)),
      signals: const {SignalKind.soc: 44},
    );

    return [
      original,
      // Byte-identical re-delivery. Must create nothing twice.
      original,
      // Arrives now, measured an hour ago. Must not become "current".
      TelemetryPacket(
        packetId: '${vehicle.vehicleId}-late',
        vehicleId: vehicle.vehicleId,
        eventTs: now.subtract(const Duration(hours: 1)),
        signals: const {SignalKind.soc: 91},
      ),
      // A backlog dump: three hours of readings arriving at once.
      for (var minutesAgo = 180; minutesAgo > 120; minutesAgo -= 10)
        TelemetryPacket(
          packetId: '${vehicle.vehicleId}-backlog-$minutesAgo',
          vehicleId: vehicle.vehicleId,
          eventTs: now.subtract(Duration(minutes: minutesAgo)),
          signals: {SignalKind.soc: 50 + (minutesAgo % 20).toDouble()},
        ),
    ];
  }

  static String _letters(int i) {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    return '${alphabet[(i ~/ 24) % 24]}${alphabet[i % 24]}';
  }
}
