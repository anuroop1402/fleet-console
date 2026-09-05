/// The database schema, as ordered migrations.
///
/// Two constraints shape everything here, both established by measurement in
/// Phase 0:
///
/// 1. **No function-valued column defaults** (`DEFAULT CURRENT_TIMESTAMP`).
///    They are reported to crash WAL replay on Android. Every timestamp is
///    supplied by the app from an injected `Clock`, which the tests need anyway.
/// 2. **Primary keys only on small tables.** A DuckDB `PRIMARY KEY` builds an
///    ART index held in memory. That is right for `latest_readings` (~3 000
///    rows) and wrong for `signal_readings` (2M+), where it would cost memory
///    on a 2.5 GB device to enforce a constraint the ingest path already
///    guarantees.
library;

/// Ordered, append-only. Never edit a migration that has shipped; add another.
///
/// Position in this list *is* the version number, so an existing database on a
/// device applies only what it has not seen. Editing a shipped migration would
/// mean devices that already ran it silently never get the change.
const List<String> migrations = [
  _migration001Initial,
  _migration002Alerts,
  _migration003Geofences,
];

const String _migration001Initial = '''
-- The fleet register. Small, slow-changing.
CREATE TABLE IF NOT EXISTS vehicles (
  vehicle_id  VARCHAR   NOT NULL,
  reg_number  VARCHAR   NOT NULL,
  model       VARCHAR   NOT NULL,
  created_at  TIMESTAMP NOT NULL,
  PRIMARY KEY (vehicle_id)
);

-- The append-only event log: one row per (packet, signal).
--
-- event_ts    - the vehicle's clock. Determines ordering and freshness.
-- ingested_ts - our clock, when the row was written. Never used for freshness;
--               used as the first tie-break when two packets share an event_ts.
-- packet_id   - final tie-break, so ordering is total and replay is
--               reproducible.
--
-- No primary key by design (see library docs). Duplicates are prevented at
-- ingest and cannot affect derived state regardless.
CREATE TABLE IF NOT EXISTS signal_readings (
  vehicle_id   VARCHAR   NOT NULL,
  signal       VARCHAR   NOT NULL,
  event_ts     TIMESTAMP NOT NULL,
  ingested_ts  TIMESTAMP NOT NULL,
  packet_id    VARCHAR   NOT NULL,
  value_num    DOUBLE    NOT NULL
);

-- Location history, separate from signal_readings because a fix is three
-- correlated values that are only meaningful together. This is the table the
-- geofence reducer replays, so its retention window is the replay horizon.
CREATE TABLE IF NOT EXISTS location_fixes (
  vehicle_id   VARCHAR   NOT NULL,
  event_ts     TIMESTAMP NOT NULL,
  ingested_ts  TIMESTAMP NOT NULL,
  packet_id    VARCHAR   NOT NULL,
  latitude     DOUBLE    NOT NULL,
  longitude    DOUBLE    NOT NULL,
  accuracy_m   DOUBLE    NOT NULL
);

-- Materialised projection: the newest reading per (vehicle, signal) by EVENT
-- time. Rebuildable from signal_readings by a single statement, so this is a
-- projection and not a second source of truth.
--
-- Why it exists: the equivalent window-function query over 2M rows measured
-- 675 ms on the target emulator in Phase 0 (39 ms on macOS, which is exactly
-- why desktop-only measurement would have hidden the problem). The fleet list
-- reads ~3 000 rows here instead.
CREATE TABLE IF NOT EXISTS latest_readings (
  vehicle_id   VARCHAR   NOT NULL,
  signal       VARCHAR   NOT NULL,
  event_ts     TIMESTAMP NOT NULL,
  ingested_ts  TIMESTAMP NOT NULL,
  packet_id    VARCHAR   NOT NULL,
  value_num    DOUBLE    NOT NULL,
  PRIMARY KEY (vehicle_id, signal)
);

-- Nothing is discarded silently. Every packet the pipeline refuses is recorded
-- with a reason, so "we never received it" and "we received it and threw it
-- away" stay distinguishable when someone asks why a trip looks wrong.
CREATE TABLE IF NOT EXISTS rejected_packets (
  vehicle_id   VARCHAR,
  packet_id    VARCHAR,
  signal       VARCHAR,
  event_ts     TIMESTAMP,
  ingested_ts  TIMESTAMP NOT NULL,
  reason       VARCHAR   NOT NULL,
  detail       VARCHAR
);
''';

const String _migration002Alerts = '''
-- One row per alert *instance*.
--
-- Identity is (vehicle_id, kind, opened_at). A condition that clears and later
-- re-fires produces a NEW row with a new opened_at rather than reviving the old
-- one, because a new occurrence deserves a fresh decision from whoever is
-- watching. Resolved rows are kept: they are the alert history, and they are
-- what makes "this truck has been low three times today" answerable.
--
-- At most one row per (vehicle_id, kind) may have resolved_at IS NULL. DuckDB
-- cannot express a partial unique index, so that invariant is enforced by the
-- evaluation code and asserted in tests rather than by the schema.
CREATE TABLE IF NOT EXISTS alerts (
  vehicle_id             VARCHAR   NOT NULL,
  kind                   VARCHAR   NOT NULL,
  opened_at              TIMESTAMP NOT NULL,

  -- Tracks the *current* condition, so it de-escalates as well as escalates.
  severity               VARCHAR   NOT NULL,

  resolved_at            TIMESTAMP,
  dismissed_at           TIMESTAMP,

  -- The severity the human was looking at when they dismissed. This is the
  -- column that makes re-escalation work: a dismissal holds only while the
  -- condition stays at or below it.
  dismissed_at_severity  VARCHAR,
  dismissal_reason       VARCHAR,

  -- The reading behind an open alert has gone stale. The alert stays open --
  -- resolving would assert a recovery we cannot see.
  is_condition_stale     BOOLEAN   NOT NULL,
  last_known_value       DOUBLE,
  last_known_at          TIMESTAMP,

  updated_at             TIMESTAMP NOT NULL,
  PRIMARY KEY (vehicle_id, kind, opened_at)
);
''';

const String _migration003Geofences = '''
-- The fence register: stable identity only. Everything that can change lives
-- in geofence_versions.
CREATE TABLE IF NOT EXISTS geofences (
  geofence_id  VARCHAR   NOT NULL,
  created_at   TIMESTAMP NOT NULL,
  PRIMARY KEY (geofence_id)
);

-- Slowly-changing dimension, type 2. Editing a fence closes the current row and
-- opens a new one; deactivating closes without reopening.
--
-- valid_from/valid_to are in EVENT time, not wall-clock, because that is what
-- history is judged against: a fix from last month is evaluated against the
-- version that was live last month. Without this, resizing a depot silently
-- rewrites every trip that ever touched it.
CREATE TABLE IF NOT EXISTS geofence_versions (
  version_id     VARCHAR   NOT NULL,
  geofence_id    VARCHAR   NOT NULL,
  name           VARCHAR   NOT NULL,
  latitude       DOUBLE    NOT NULL,
  longitude      DOUBLE    NOT NULL,
  radius_m       DOUBLE    NOT NULL,
  valid_from     TIMESTAMP NOT NULL,
  valid_to       TIMESTAMP,
  is_active      BOOLEAN   NOT NULL,
  created_at     TIMESTAMP NOT NULL,
  PRIMARY KEY (version_id)
);

-- DERIVED. A pure function of (location_fixes x geofence_versions), rebuilt by
-- replay. If this table and the fix log ever disagree, the log wins.
CREATE TABLE IF NOT EXISTS geofence_visits (
  vehicle_id           VARCHAR   NOT NULL,
  geofence_id          VARCHAR   NOT NULL,
  version_id           VARCHAR   NOT NULL,
  entered_at           TIMESTAMP NOT NULL,
  exited_at            TIMESTAMP,
  inferred_during_gap  BOOLEAN   NOT NULL,
  PRIMARY KEY (vehicle_id, geofence_id, entered_at)
);

-- DERIVED, same contract as geofence_visits.
--
-- trip_id is derived from (vehicle_id, started_at) rather than generated, so a
-- replay reproduces the same rows instead of a parallel set of duplicates. That
-- single property is what lets a late packet revise a boundary without
-- doubling the trip.
CREATE TABLE IF NOT EXISTS trips (
  trip_id                  VARCHAR   NOT NULL,
  vehicle_id               VARCHAR   NOT NULL,
  status                   VARCHAR   NOT NULL,
  started_at               TIMESTAMP NOT NULL,
  origin_geofence_id       VARCHAR,
  origin_version_id        VARCHAR,
  ended_at                 TIMESTAMP,
  destination_geofence_id  VARCHAR,
  destination_version_id   VARCHAR,
  destination_unknown      BOOLEAN   NOT NULL,
  inferred_during_gap      BOOLEAN   NOT NULL,
  PRIMARY KEY (trip_id)
);
''';

/// Why a packet or reading was refused. Stored as text in `rejected_packets`,
/// so these strings are part of the on-disk format.
enum RejectionReason {
  /// Exact repeat of a row already in the log.
  duplicate('duplicate'),

  /// Event time is implausibly far ahead of our clock.
  clockSkewAhead('clock_skew_ahead'),

  /// Older than the retention window, so it can never be replayed.
  beyondRetention('beyond_retention'),

  /// Structurally unusable — no signals and no location, or a bad value.
  malformed('malformed');

  const RejectionReason(this.wireName);

  final String wireName;
}
