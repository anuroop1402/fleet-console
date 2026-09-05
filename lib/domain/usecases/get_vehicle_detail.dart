/// Builds the readings register for one vehicle.
library;

import '../../core/clock.dart';
import '../../core/constants.dart';
import '../entities/fleet_view.dart';
import '../entities/signal_kind.dart';
import '../entities/signal_reading.dart';
import '../entities/verdict.dart';
import '../repositories/fleet_repository.dart';
import '../rules/staleness.dart';
import '../rules/status_rules.dart';

/// Turns raw readings into the register the detail screen displays.
///
/// This is the use case that earns its place. The repository hands back values
/// and timestamps; deciding what each one *means* — fresh or stale, within
/// threshold or outside it, never reported at all — is domain logic that needs
/// both the clock and the threshold rules. Doing it in the widget would put
/// business rules in a build method; doing it in SQL would duplicate them.
final class GetVehicleDetail {
  const GetVehicleDetail({
    required FleetRepository repository,
    required Clock clock,
  }) : _repository = repository,
       _clock = clock;

  final FleetRepository _repository;
  final Clock _clock;

  /// The order rows appear in the register.
  ///
  /// Fixed rather than derived from whatever the vehicle happens to report, so
  /// the screen does not reshuffle as packets arrive, and so a signal that has
  /// never reported still occupies its row showing "—".
  static const List<SignalKind> registerOrder = [
    SignalKind.soc,
    SignalKind.rangeKm,
    SignalKind.speed,
    SignalKind.batteryTemp,
    SignalKind.odometer,
    SignalKind.ignition,
  ];

  Future<VehicleDetail?> call(String vehicleId) async {
    final readings = await _repository.vehicleReadings(vehicleId);
    if (readings == null) return null;

    // One instant for the whole screen. Reading the clock per row would let
    // two signals of identical age disagree about whether they are stale.
    final now = _clock.nowUtc();
    final snapshot = readings.snapshot;

    final register = [
      for (final kind in registerOrder)
        _rowFor(kind, snapshot[kind], now),
    ];

    return VehicleDetail(
      vehicleId: readings.vehicle.vehicleId,
      regNumber: readings.vehicle.regNumber,
      model: readings.vehicle.model,
      status: statusOf(snapshot, now),
      register: register,
      lastPing: snapshot.lastPing,
    );
  }

  RegisterRow _rowFor(SignalKind kind, SignalReading? reading, DateTime now) {
    final verdict = verdictFor(kind: kind, reading: reading, now: now);
    if (reading == null || verdict == Verdict.neverReported) {
      return RegisterRow(kind: kind, verdict: verdict);
    }
    return RegisterRow(
      kind: kind,
      verdict: verdict,
      value: reading.value,
      eventTs: reading.eventTs,
      age: reading.ageAt(now),
    );
  }
}

/// SOC history over the retained window.
final class GetSocHistory {
  const GetSocHistory({
    required FleetRepository repository,
    required Clock clock,
  }) : _repository = repository,
       _clock = clock;

  final FleetRepository _repository;
  final Clock _clock;

  /// The window is the raw-signal retention period: past that, full-resolution
  /// readings have been rolled up, so asking for them would return a
  /// misleadingly sparse line rather than an honest one.
  Future<List<SocSample>> call(String vehicleId, {int maxPoints = 200}) =>
      _repository.socHistory(
        vehicleId,
        since: _clock.nowUtc().subtract(RetentionPolicy.rawSignals),
        maxPoints: maxPoints,
      );
}
