/// An in-memory [FleetRepository] for domain and presentation tests.
///
/// Its existence is the point of the layering: because BLoCs depend on use
/// cases and use cases depend on this interface, the whole presentation layer
/// can be tested with no database and no native library. If a test ever needs
/// DuckDB to exercise a BLoC, a dependency has leaked.
library;

import 'package:fleet_console/domain/entities/fleet_view.dart';
import 'package:fleet_console/domain/entities/vehicle_status.dart';
import 'package:fleet_console/domain/repositories/fleet_repository.dart';

final class FakeFleetRepository implements FleetRepository {
  FakeFleetRepository({
    List<FleetListItem> items = const [],
    Map<String, VehicleReadings> readings = const {},
    List<SocSample> history = const [],
  }) : _items = List.of(items),
       _readings = Map.of(readings),
       _history = List.of(history);

  List<FleetListItem> _items;
  final Map<String, VehicleReadings> _readings;
  List<SocSample> _history;

  /// Set to make any read throw, for error-path tests.
  Object? failWith;

  /// Records the instants the use cases passed down, so tests can assert that
  /// "now" is read once per refresh rather than per query.
  final List<DateTime> observedNows = [];

  /// Records the arguments of the last history call.
  DateTime? lastHistorySince;
  int? lastHistoryMaxPoints;

  void setItems(List<FleetListItem> items) => _items = List.of(items);
  void setHistory(List<SocSample> samples) => _history = List.of(samples);
  void setReadings(String vehicleId, VehicleReadings readings) =>
      _readings[vehicleId] = readings;

  @override
  Future<List<FleetListItem>> fleetList({
    required DateTime now,
    VehicleStatus? status,
  }) async {
    _throwIfFailing();
    observedNows.add(now);
    if (status == null) return List.of(_items);
    return _items.where((item) => item.status == status).toList();
  }

  @override
  Future<Map<VehicleStatus, int>> statusCounts({required DateTime now}) async {
    _throwIfFailing();
    observedNows.add(now);
    final counts = <VehicleStatus, int>{};
    for (final item in _items) {
      counts.update(item.status, (n) => n + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  @override
  Future<VehicleReadings?> vehicleReadings(String vehicleId) async {
    _throwIfFailing();
    return _readings[vehicleId];
  }

  @override
  Future<List<SocSample>> socHistory(
    String vehicleId, {
    required DateTime since,
    int maxPoints = 200,
  }) async {
    _throwIfFailing();
    lastHistorySince = since;
    lastHistoryMaxPoints = maxPoints;
    return _history.where((s) => !s.eventTs.isBefore(since)).toList();
  }

  @override
  Future<void> upsertVehicles(List<Vehicle> vehicles) async {}

  @override
  Future<int> vehicleCount() async => _items.length;

  void _throwIfFailing() {
    final failure = failWith;
    if (failure != null) throw failure;
  }
}
