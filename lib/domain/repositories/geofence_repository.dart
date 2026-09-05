/// Persistence for geofences and the derived tables built from them.
library;

import '../entities/geofence.dart';

abstract interface class GeofenceRepository {
  /// Every version, including closed and deactivated ones.
  ///
  /// Replay needs the closed ones: a fix from last month has to be judged
  /// against the fence as it was last month.
  Future<List<GeofenceVersion>> allVersions();

  /// Only versions still open and active — what the management screen edits.
  Future<List<GeofenceVersion>> currentVersions();

  /// Creates a fence and its first version.
  Future<GeofenceVersion> create({
    required String name,
    required double latitude,
    required double longitude,
    required double radiusMetres,
    required DateTime at,
  });

  /// Closes the current version and opens a new one carrying the edits.
  ///
  /// Never an in-place update: history has to keep pointing at the shape the
  /// fence had when a trip crossed it.
  Future<GeofenceVersion> edit({
    required String geofenceId,
    required String name,
    required double latitude,
    required double longitude,
    required double radiusMetres,
    required DateTime at,
  });

  /// Closes the current version without opening a replacement.
  ///
  /// A deactivated fence stops producing new transitions but keeps its
  /// history, which is what the brief means by retaining it for trip history.
  Future<void> deactivate({
    required String geofenceId,
    required DateTime at,
  });

  Future<void> reactivate({required String geofenceId, required DateTime at});
}

/// Reads and writes the tables derived from the fix log.
abstract interface class TripRepository {
  Future<List<Trip>> tripsFor(String vehicleId, {int limit});

  Future<List<Trip>> recentTrips({int limit});

  Future<List<GeofenceVisit>> visitsFor(String vehicleId, {int limit});

  /// Live vehicle count per geofence, for the management screen.
  Future<Map<String, int>> vehicleCountsByGeofence();

  /// Where each vehicle currently is, single-valued.
  Future<Map<String, String>> currentGeofenceByVehicle();
}

/// The location log the reducer replays.
abstract interface class LocationFixSource {
  /// Fixes for one vehicle at or after [from], in no guaranteed order.
  Future<List<LocationFix>> fixesFor(String vehicleId, {DateTime? from});

  /// Vehicles with at least one fix at or after [since].
  Future<List<String>> vehiclesWithFixesSince(DateTime since);
}
