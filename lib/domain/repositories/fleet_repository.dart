/// What the app needs from storage, expressed without naming a database.
///
/// The interface lives in the domain and the implementation in `data/`, so the
/// dependency points inwards. Nothing here mentions DuckDB, SQL or rows.
library;

import '../entities/fleet_view.dart';
import '../entities/vehicle_status.dart';

abstract interface class FleetRepository {
  /// One row per vehicle, newest-known values, optionally filtered.
  ///
  /// [now] is passed in rather than read inside, because status depends on
  /// elapsed time and the caller owns the clock. It also means the SQL is
  /// deterministic and can be tested against a fixed instant.
  Future<List<FleetListItem>> fleetList({
    required DateTime now,
    VehicleStatus? status,
  });

  /// Live counts for the filter chips, computed in SQL over the same rules as
  /// [fleetList] so a chip can never disagree with the list it filters.
  Future<Map<VehicleStatus, int>> statusCounts({required DateTime now});

  /// Raw readings for one vehicle. Returns null when the vehicle is unknown.
  ///
  /// Deliberately raw: turning readings into verdicts needs the threshold rules
  /// and the clock, which belong in the use case, not in storage.
  Future<VehicleReadings?> vehicleReadings(String vehicleId);

  /// SOC over the retained window, oldest first.
  Future<List<SocSample>> socHistory(
    String vehicleId, {
    required DateTime since,
    int maxPoints,
  });

  /// The fleet register.
  Future<void> upsertVehicles(List<Vehicle> vehicles);

  Future<int> vehicleCount();
}
