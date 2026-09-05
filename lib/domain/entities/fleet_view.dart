/// What the fleet list and the vehicle detail screen actually show.
///
/// These are domain entities, not presentation models. They carry the *answers*
/// — status, verdict, age — rather than raw rows for a widget to interpret,
/// because deciding whether a reading is stale is a domain rule and must not be
/// re-implemented in a build method.
library;

import 'package:equatable/equatable.dart';

import 'signal_kind.dart';
import 'signal_reading.dart';
import 'vehicle_status.dart';
import 'verdict.dart';

/// One row of the fleet list.
final class FleetListItem extends Equatable {
  const FleetListItem({
    required this.vehicleId,
    required this.regNumber,
    required this.model,
    required this.status,
    this.soc,
    this.socEventTs,
    this.rangeKm,
    this.openAlertCount = 0,
    this.hasCriticalAlert = false,
    this.lastPing,
  });

  final String vehicleId;
  final String regNumber;
  final String model;

  /// Computed in SQL, as the brief requires. `statusOf` in the domain is the
  /// reference implementation the SQL is tested against.
  final VehicleStatus status;

  /// The most recent SOC we hold, regardless of age.
  final double? soc;

  /// When that SOC was measured, so the list can grey out a stale value rather
  /// than presenting it as current. Showing "82%" from three hours ago with no
  /// hint is the kind of quietly-wrong number this app exists to avoid.
  final DateTime? socEventTs;

  final double? rangeKm;

  final int openAlertCount;
  final bool hasCriticalAlert;

  final DateTime? lastPing;

  bool get hasAlert => openAlertCount > 0;

  /// Whether the SOC shown is old enough that it should not be trusted.
  bool socIsStale(DateTime now, Duration staleAfter) =>
      socEventTs == null || now.difference(socEventTs!) > staleAfter;

  @override
  List<Object?> get props => [
    vehicleId,
    regNumber,
    model,
    status,
    soc,
    socEventTs,
    rangeKm,
    openAlertCount,
    hasCriticalAlert,
    lastPing,
  ];
}

/// One line of the readings register on the vehicle detail screen.
final class RegisterRow extends Equatable {
  const RegisterRow({
    required this.kind,
    required this.verdict,
    this.value,
    this.eventTs,
    this.age,
  });

  final SignalKind kind;

  /// NORMAL, ALERT, STALE, or neverReported — decided in the domain.
  final Verdict verdict;

  /// Null only when the signal has never reported.
  final double? value;
  final DateTime? eventTs;

  /// This signal's *own* age, deliberately independent of the vehicle-level
  /// freshness that drives the status chip.
  final Duration? age;

  bool get hasEverReported => verdict != Verdict.neverReported;

  @override
  List<Object?> get props => [kind, verdict, value, eventTs, age];
}

/// Everything the vehicle detail screen needs.
final class VehicleDetail extends Equatable {
  const VehicleDetail({
    required this.vehicleId,
    required this.regNumber,
    required this.model,
    required this.status,
    required this.register,
    this.lastPing,
  });

  final String vehicleId;
  final String regNumber;
  final String model;
  final VehicleStatus status;

  /// One row per signal, in a fixed display order, including signals that have
  /// never reported.
  final List<RegisterRow> register;

  final DateTime? lastPing;

  @override
  List<Object?> get props => [
    vehicleId,
    regNumber,
    model,
    status,
    register,
    lastPing,
  ];
}

/// One point on the SOC history chart.
final class SocSample extends Equatable {
  const SocSample({required this.eventTs, required this.value});

  final DateTime eventTs;
  final double value;

  @override
  List<Object?> get props => [eventTs, value];
}

/// A vehicle's identity, as held in the fleet register.
final class Vehicle extends Equatable {
  const Vehicle({
    required this.vehicleId,
    required this.regNumber,
    required this.model,
  });

  final String vehicleId;
  final String regNumber;
  final String model;

  @override
  List<Object?> get props => [vehicleId, regNumber, model];
}

/// The raw materials the domain needs to build a [VehicleDetail].
///
/// The repository returns this; the use case turns it into verdicts and ages,
/// because that requires the clock and the threshold rules.
final class VehicleReadings extends Equatable {
  const VehicleReadings({required this.vehicle, required this.snapshot});

  final Vehicle vehicle;
  final VehicleSnapshot snapshot;

  @override
  List<Object?> get props => [vehicle, snapshot];
}
