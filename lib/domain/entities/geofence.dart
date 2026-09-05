/// Geofences, their versions, and what a vehicle did around them.
library;

import 'package:equatable/equatable.dart';

/// One version of a circular geofence, valid over a window of *event* time.
///
/// Geofences are versioned (SCD-2) rather than mutated in place. Editing one
/// creates a new version; deactivating closes the current one. History is
/// always evaluated against the version in effect at the fix's event time.
///
/// The alternative — evaluating history against the current definition — means
/// resizing a depot silently rewrites last month's trips. That is a bug, not a
/// feature, and the brief's requirement to "retain deactivated geofences for
/// trip history" only makes sense if history stays interpretable.
final class GeofenceVersion extends Equatable {
  const GeofenceVersion({
    required this.geofenceId,
    required this.versionId,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.radiusMetres,
    required this.validFrom,
    this.validTo,
    this.isActive = true,
  });

  /// Stable across versions. Two versions of the same fence share this.
  final String geofenceId;

  /// Unique per version. Trips reference this, so a trip records the fence
  /// *as it was* when the trip happened.
  final String versionId;

  final String name;
  final double latitude;
  final double longitude;
  final double radiusMetres;

  /// Event-time validity window. [validTo] null means "still current".
  final DateTime validFrom;
  final DateTime? validTo;

  /// A deactivated fence stops generating new transitions but keeps its
  /// history. Deactivation is a version boundary, not a delete.
  final bool isActive;

  bool coversEventTime(DateTime eventTs) =>
      !eventTs.isBefore(validFrom) &&
      (validTo == null || eventTs.isBefore(validTo!));

  /// Whether this version should produce transitions for a fix at [eventTs].
  bool isLiveAt(DateTime eventTs) => isActive && coversEventTime(eventTs);

  @override
  List<Object?> get props => [
    geofenceId,
    versionId,
    name,
    latitude,
    longitude,
    radiusMetres,
    validFrom,
    validTo,
    isActive,
  ];
}

/// A location observation, as the reducer sees it.
final class LocationFix extends Equatable {
  const LocationFix({
    required this.vehicleId,
    required this.eventTs,
    required this.ingestedTs,
    required this.packetId,
    required this.latitude,
    required this.longitude,
    required this.accuracyMetres,
  });

  final String vehicleId;

  /// When the vehicle took the fix. Ordering and dwell are event-time.
  final DateTime eventTs;

  /// When we received it. Only ever a tie-break.
  final DateTime ingestedTs;

  final String packetId;
  final double latitude;
  final double longitude;
  final double accuracyMetres;

  /// Total order, so replaying the same log always produces the same result.
  ///
  /// Event time first, then arrival (a later arrival is most plausibly a
  /// correction), then packet id as the final deterministic tie-break.
  static int compare(LocationFix a, LocationFix b) {
    final byEvent = a.eventTs.compareTo(b.eventTs);
    if (byEvent != 0) return byEvent;
    final byIngest = a.ingestedTs.compareTo(b.ingestedTs);
    if (byIngest != 0) return byIngest;
    return a.packetId.compareTo(b.packetId);
  }

  @override
  List<Object?> get props => [
    vehicleId,
    eventTs,
    ingestedTs,
    packetId,
    latitude,
    longitude,
    accuracyMetres,
  ];
}

/// Why a fix was excluded from the reduction.
enum FixRejection {
  /// Same vehicle and event time as a fix already accepted.
  duplicate('duplicate'),

  /// Accuracy so poor the fix cannot decide any fence.
  tooInaccurate('too_inaccurate'),

  /// Implied speed from the previous accepted fix is physically impossible.
  /// A bad fix, not a fast truck.
  teleport('teleport');

  const FixRejection(this.wireName);

  final String wireName;
}

/// A confirmed crossing of a geofence boundary.
enum TransitionKind { entry, exit }

final class ConfirmedTransition extends Equatable {
  const ConfirmedTransition({
    required this.vehicleId,
    required this.geofenceId,
    required this.versionId,
    required this.kind,
    required this.crossedAt,
    required this.confirmedAt,
    this.inferredDuringGap = false,
  });

  final String vehicleId;
  final String geofenceId;
  final String versionId;
  final TransitionKind kind;

  /// The event time of the *first* fix in the run that established the new
  /// state — i.e. when the truck actually crossed.
  final DateTime crossedAt;

  /// The event time of the fix that satisfied the confirmation rule. Later
  /// than [crossedAt] by construction. Kept for audit: users see the crossing,
  /// but "why did you only notice at 14:07" needs an answer.
  final DateTime confirmedAt;

  /// The crossing happened inside a reporting gap, so [crossedAt] is the first
  /// fix *after* the gap rather than the true moment. Honest-but-late, and
  /// flagged rather than fabricated.
  final bool inferredDuringGap;

  @override
  List<Object?> get props => [
    vehicleId,
    geofenceId,
    versionId,
    kind,
    crossedAt,
    confirmedAt,
    inferredDuringGap,
  ];
}

/// A period a vehicle was confirmed to be inside a fence.
final class GeofenceVisit extends Equatable {
  const GeofenceVisit({
    required this.vehicleId,
    required this.geofenceId,
    required this.versionId,
    required this.enteredAt,
    this.exitedAt,
    this.inferredDuringGap = false,
  });

  final String vehicleId;
  final String geofenceId;
  final String versionId;
  final DateTime enteredAt;

  /// Null while the vehicle is still inside.
  final DateTime? exitedAt;

  final bool inferredDuringGap;

  bool get isOpen => exitedAt == null;

  @override
  List<Object?> get props => [
    vehicleId,
    geofenceId,
    versionId,
    enteredAt,
    exitedAt,
    inferredDuringGap,
  ];
}

enum TripStatus {
  inProgress('in_progress'),
  completed('completed');

  const TripStatus(this.wireName);

  final String wireName;
}

/// A journey between two confirmed geofence transitions.
final class Trip extends Equatable {
  const Trip({
    required this.tripId,
    required this.vehicleId,
    required this.status,
    required this.startedAt,
    this.originGeofenceId,
    this.originVersionId,
    this.destinationGeofenceId,
    this.destinationVersionId,
    this.endedAt,
    this.destinationUnknown = false,
    this.inferredDuringGap = false,
  });

  /// Derived deterministically from (vehicleId, startedAt), so replaying the
  /// same log produces the same id. A random uuid would make replay produce
  /// "new" trips every time and defeat idempotency.
  final String tripId;

  final String vehicleId;
  final TripStatus status;

  /// The confirmed exit that started it — the crossing, not the confirmation.
  final DateTime startedAt;
  final String? originGeofenceId;
  final String? originVersionId;

  final DateTime? endedAt;
  final String? destinationGeofenceId;
  final String? destinationVersionId;

  /// The trip ended without a confirmed entry anywhere — closed because the
  /// vehicle turned up leaving somewhere else. Distinct from IN PROGRESS,
  /// which means we are still waiting.
  final bool destinationUnknown;

  final bool inferredDuringGap;

  /// Returning to the origin is valid and is not deduped away — a delivery run
  /// that comes home is still a trip.
  bool get returnedToOrigin =>
      originGeofenceId != null &&
      originGeofenceId == destinationGeofenceId;

  Duration? get duration => endedAt?.difference(startedAt);

  @override
  List<Object?> get props => [
    tripId,
    vehicleId,
    status,
    startedAt,
    originGeofenceId,
    originVersionId,
    endedAt,
    destinationGeofenceId,
    destinationVersionId,
    destinationUnknown,
    inferredDuringGap,
  ];
}
