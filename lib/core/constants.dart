/// Every threshold in the system, named once.
///
/// Magic numbers scattered through rules cannot be reviewed, and cannot be
/// changed with confidence. Anything a reviewer might argue with lives here.
library;

/// Thresholds taken directly from the brief.
abstract final class FleetThresholds {
  /// A vehicle is OFFLINE when its most recent signal — across *all* signals —
  /// is older than this. Vehicle-level, deliberately distinct from the
  /// per-signal staleness used by the readings register.
  static const Duration offlineAfter = Duration(minutes: 10);

  /// A single reading older than this is STALE: too old to make a
  /// normal/alert claim about.
  static const Duration signalStaleAfter = Duration(minutes: 10);

  /// SOC below this is a warning. The two SOC thresholds are one escalating
  /// alert, not two — see docs/01 §3.
  static const double socWarningPercent = 20;

  /// SOC below this escalates the same alert to critical.
  static const double socCriticalPercent = 10;

  /// Battery temperature above this is critical.
  static const double batteryTempCriticalCelsius = 45;

  /// How long a dismissed alert can be restored by UNDO.
  static const Duration undoWindow = Duration(seconds: 5);
}

/// Rules governing what the ingest pipeline will accept.
abstract final class IngestPolicy {
  /// A packet whose event time is further in the future than this is rejected.
  ///
  /// Vehicle clocks drift and occasionally reset. Without this guard, one truck
  /// reporting the year 2031 would permanently win every "latest reading"
  /// comparison and could never be corrected — the event-time ordering that
  /// everything else depends on has no way to recover from it.
  static const Duration maxClockSkewAhead = Duration(minutes: 5);

  /// How far back the exact-duplicate check looks.
  ///
  /// Bounded on purpose: an unbounded anti-join scans the whole log on every
  /// ingest. DuckDB's zone maps prune an `event_ts` range cheaply, so this stays
  /// fast as the log grows. Duplicates older than this can reach the raw log,
  /// but cannot affect any derived value — the projection guard and the
  /// reducers are both idempotent by event time.
  static const Duration duplicateLookback = Duration(hours: 24);
}

/// The deterministic strategy for turning noisy GPS into geofence transitions.
///
/// The brief names seven failure modes — duplicates, late packets, jitter,
/// inaccurate readings, overlaps, missing intervals and geofence edits. These
/// are the numbers that resolve them. Every one is a judgement call, so every
/// one is named here where it can be argued with.
abstract final class GeofencePolicy {
  /// A fix worse than this cannot decide any fence we would plausibly draw,
  /// so it is dropped rather than allowed to vote.
  static const double maxUsableAccuracyMetres = 200;

  /// Minimum hysteresis band, even for a pin-sharp fix.
  ///
  /// Membership is not a bare radius test. Inside requires `d < R - buffer`,
  /// outside requires `d > R + buffer`, and between the two the state is
  /// *sticky*. Without this a truck parked on a boundary generates an endless
  /// stream of entries and exits — and therefore an endless stream of trips.
  static const double minHysteresisMetres = 15;

  /// A fix implying more than this from the previous accepted fix is a bad
  /// fix, not a fast truck.
  static const double maxPlausibleSpeedKmh = 200;

  /// Consecutive agreeing fixes needed before a transition is *confirmed*.
  ///
  /// Feature E's "confirmed exit" and "confirmed entry" are exactly this
  /// debounce. One fix is an opinion; two in a row that also survive the dwell
  /// window are a crossing.
  static const int confirmationFixes = 2;

  /// Minimum time in the new state before a transition is confirmed.
  static const Duration confirmationDwell = Duration(seconds: 60);

  /// A silence longer than this breaks the dwell chain.
  ///
  /// After a gap we cannot claim continuous presence, so state is
  /// re-established from scratch and anything inferred across the gap is
  /// stamped at the first post-gap fix and flagged. Honest-but-late beats a
  /// fabricated timestamp.
  static const Duration maxReportingGap = Duration(minutes: 30);
}

/// What is kept, and for how long. An append-only log grows forever.
///
/// The coupling worth stating out loud: **raw retention is the replay horizon.**
/// Derived tables are rebuilt by replaying the raw log, so a packet older than
/// the retention window cannot be replayed and is rejected rather than
/// silently applied.
abstract final class RetentionPolicy {
  /// Full-resolution signal readings. Beyond this they are rolled up hourly.
  static const Duration rawSignals = Duration(days: 7);

  /// Raw location fixes. This is what bounds late-packet replay.
  static const Duration rawLocationFixes = Duration(days: 30);
}
