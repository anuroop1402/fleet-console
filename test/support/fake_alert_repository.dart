/// An in-memory [AlertRepository] for use-case and BLoC tests.
library;

import 'package:fleet_console/domain/entities/alert.dart';
import 'package:fleet_console/domain/entities/fleet_view.dart';
import 'package:fleet_console/domain/entities/signal_reading.dart';
import 'package:fleet_console/domain/repositories/alert_repository.dart';

final class FakeAlertRepository implements AlertRepository {
  FakeAlertRepository({List<Alert> alerts = const []})
    : _alerts = List.of(alerts);

  List<Alert> _alerts;

  /// Set to make any call throw, for error-path tests.
  Object? failWith;

  /// Every `applyTransitions` call, for asserting the sweep wrote once.
  int applyCallCount = 0;

  void setAlerts(List<Alert> alerts) => _alerts = List.of(alerts);

  List<Alert> get all => List.unmodifiable(_alerts);

  @override
  Future<List<Alert>> openAlerts() async {
    _throwIfFailing();
    return _alerts.where((a) => a.resolvedMarker == false).toList();
  }

  @override
  Future<List<AlertView>> visibleAlerts() async {
    _throwIfFailing();
    return _alerts
        .where((a) => a.resolvedMarker == false && !a.isDismissed)
        .map((a) => AlertView(alert: a, regNumber: 'REG-${a.vehicleId}'))
        .toList();
  }

  @override
  Future<void> applyTransitions({
    required List<Alert> upserts,
    required List<Alert> resolved,
    required DateTime now,
  }) async {
    _throwIfFailing();
    applyCallCount++;

    for (final alert in resolved) {
      _alerts.removeWhere((a) => _same(a, alert));
    }
    for (final alert in upserts) {
      final index = _alerts.indexWhere((a) => _same(a, alert));
      if (index >= 0) {
        _alerts[index] = alert;
      } else {
        _alerts.add(alert);
      }
    }
  }

  @override
  Future<void> saveDismissal(Alert alert) async {
    _throwIfFailing();
    final index = _alerts.indexWhere((a) => _same(a, alert));
    if (index >= 0) {
      _alerts[index] = alert;
    } else {
      _alerts.add(alert);
    }
  }

  @override
  Future<List<Alert>> alertHistory(String vehicleId, {int limit = 50}) async {
    _throwIfFailing();
    return _alerts.where((a) => a.vehicleId == vehicleId).take(limit).toList();
  }

  static bool _same(Alert a, Alert b) =>
      a.vehicleId == b.vehicleId &&
      a.kind == b.kind &&
      a.openedAt == b.openedAt;

  void _throwIfFailing() {
    final failure = failWith;
    if (failure != null) throw failure;
  }
}

/// The fake drops resolved alerts rather than storing a resolved_at, so this is
/// always false. Kept as an extension so the fake reads like the real thing.
extension on Alert {
  bool get resolvedMarker => false;
}

/// A snapshot source that returns whatever the test hands it.
final class FakeSnapshotSource implements FleetSnapshotSource {
  FakeSnapshotSource([Map<String, VehicleSnapshot>? snapshots])
    : _snapshots = snapshots ?? {};

  Map<String, VehicleSnapshot> _snapshots;

  void setSnapshots(Map<String, VehicleSnapshot> snapshots) =>
      _snapshots = snapshots;

  @override
  Future<Map<String, VehicleSnapshot>> allVehicleSnapshots() async =>
      Map.of(_snapshots);
}
