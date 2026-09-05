/// SQL for the fleet screens, as named constants rather than inline literals.
///
/// The status rule exists twice: here in SQL, and as `statusOf` in
/// `domain/rules/status_rules.dart`. That duplication is deliberate — the brief
/// requires the chip counts to be computed in SQL, and pulling 500 vehicles
/// into Dart to classify them would defeat the projection that makes the list
/// fast. The duplication is made safe by
/// `test/data/sql_status_agrees_with_domain_test.dart`, which drives the same
/// matrix of cases through both and asserts they never disagree.
library;

/// Per-vehicle rollup of the projection, plus the status expression.
///
/// Parameters, in order:
///   1. fresh-from  — readings at or after this are fresh enough to classify
///   2. online-from — a vehicle pinging at or after this is online
///
/// `latest_readings` holds one row per (vehicle, signal), so the `MAX(CASE …)`
/// aggregates are picking a single value each, not reducing over history.
///
/// The joins start from `vehicles`, so a vehicle that has never reported still
/// appears — as OFFLINE, which is the honest answer rather than an omission.
const String fleetRollupCte = '''
WITH per_vehicle AS (
  SELECT
    vehicle_id,
    MAX(event_ts) AS last_ping,
    MAX(CASE WHEN signal = 'speed'    AND event_ts >= ? THEN value_num END) AS fresh_speed,
    MAX(CASE WHEN signal = 'ignition' AND event_ts >= ? THEN value_num END) AS fresh_ignition,
    MAX(CASE WHEN signal = 'soc'      THEN value_num END) AS soc,
    MAX(CASE WHEN signal = 'soc'      THEN event_ts  END) AS soc_event_ts,
    MAX(CASE WHEN signal = 'range'    THEN value_num END) AS range_km
  FROM latest_readings
  GROUP BY vehicle_id
),
-- Open, undismissed alerts per vehicle. Dismissed ones are deliberately
-- excluded: a dismissal means a human chose not to be shown it, so counting it
-- in the badge would defeat the dismissal while still hiding the alert itself.
alert_counts AS (
  SELECT
    vehicle_id,
    COUNT(*) AS open_alerts,
    MAX(CASE WHEN severity = 'critical' THEN 1 ELSE 0 END) AS has_critical
  FROM alerts
  WHERE resolved_at IS NULL AND dismissed_at IS NULL
  GROUP BY vehicle_id
),
classified AS (
  SELECT
    v.vehicle_id,
    v.reg_number,
    v.model,
    p.last_ping,
    p.soc,
    p.soc_event_ts,
    p.range_km,
    COALESCE(a.open_alerts, 0) AS open_alerts,
    COALESCE(a.has_critical, 0) AS has_critical,
    CASE
      -- First match wins, in the order the brief specifies. Vehicle-level
      -- freshness first: OFFLINE outranks everything, including a speed
      -- reading that would otherwise say MOVING.
      WHEN p.last_ping IS NULL OR p.last_ping < ? THEN 'offline'
      WHEN p.fresh_speed > 0 THEN 'moving'
      WHEN p.fresh_speed = 0 AND p.fresh_ignition IS NOT NULL
           AND p.fresh_ignition != 0 THEN 'idle'
      WHEN p.fresh_ignition = 0 THEN 'stopped'
      -- Online, but nothing fresh enough to classify. Not STOPPED: that would
      -- assert ignition-off from an absence of evidence.
      ELSE 'unknown'
    END AS status
  FROM vehicles v
  LEFT JOIN per_vehicle p ON p.vehicle_id = v.vehicle_id
  LEFT JOIN alert_counts a ON a.vehicle_id = v.vehicle_id
)
''';

/// The fleet list. Append a status filter and ordering.
const String selectFleetList = '''
$fleetRollupCte
SELECT vehicle_id, reg_number, model, status, soc, soc_event_ts, range_km,
       last_ping, open_alerts, has_critical
FROM classified
ORDER BY has_critical DESC, open_alerts DESC, reg_number
''';

/// The fleet list, filtered to one status.
const String selectFleetListFiltered = '''
$fleetRollupCte
SELECT vehicle_id, reg_number, model, status, soc, soc_event_ts, range_km,
       last_ping, open_alerts, has_critical
FROM classified
WHERE status = ?
ORDER BY has_critical DESC, open_alerts DESC, reg_number
''';

/// Live counts for the filter chips, over exactly the same expression as the
/// list — so a chip can never disagree with what tapping it shows.
const String selectStatusCounts = '''
$fleetRollupCte
SELECT status, COUNT(*) AS n
FROM classified
GROUP BY status
''';

/// Every vehicle's latest readings, in one read.
///
/// Alert evaluation sweeps the whole fleet, so fetching per vehicle would be one
/// round-trip to the connection isolate per truck.
const String selectAllLatestReadings = '''
SELECT vehicle_id, signal, value_num, event_ts
FROM latest_readings
ORDER BY vehicle_id
''';

/// Everything currently known about one vehicle's signals.
const String selectVehicleReadings = '''
SELECT v.reg_number, v.model, r.signal, r.value_num, r.event_ts
FROM vehicles v
LEFT JOIN latest_readings r ON r.vehicle_id = v.vehicle_id
WHERE v.vehicle_id = ?
''';

/// SOC over the retained window.
///
/// Down-sampled in SQL rather than in Dart: a week of one-minute readings is
/// ~10 000 points for a chart a few hundred pixels wide, and ferrying them
/// across the FFI boundary to throw most away is pure waste. Bucketing keeps
/// the shape of the line and bounds the transfer.
const String selectSocHistory = '''
WITH bucketed AS (
  SELECT
    event_ts,
    value_num,
    NTILE(?) OVER (ORDER BY event_ts) AS bucket
  FROM signal_readings
  WHERE vehicle_id = ? AND signal = 'soc' AND event_ts >= ?
)
SELECT MIN(event_ts) AS event_ts, AVG(value_num) AS value_num
FROM bucketed
GROUP BY bucket
ORDER BY event_ts
''';
