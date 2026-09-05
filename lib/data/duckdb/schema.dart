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
const List<String> migrations = [
  _migration001Initial,
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
