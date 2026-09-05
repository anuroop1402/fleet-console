/// The named telemetry parameters a packet can carry.
///
/// One packet carries a *subset* of these — the brief is explicit that packets
/// are partial. A signal that has never reported is represented by the absence
/// of a row, which is why the UI can distinguish "—" (never seen) from STALE
/// (seen, too old to trust).
library;

enum SignalKind {
  /// Battery state of charge, percent.
  soc('soc'),

  /// Instantaneous speed, km/h.
  speed('speed'),

  /// Battery temperature, °C.
  batteryTemp('battery_temp'),

  /// Lifetime distance, km. Monotonic in principle; not relied on to be.
  odometer('odometer'),

  /// Estimated remaining range, km.
  rangeKm('range'),

  /// Vehicle switched on. Stored as 0.0 / 1.0 — see note below.
  ignition('ignition');

  const SignalKind(this.wireName);

  /// The value stored in the `signal` column. Fixed and stable: it is written
  /// into the database, so renaming an enum constant must not change it.
  final String wireName;

  static final Map<String, SignalKind> _byWireName = {
    for (final kind in SignalKind.values) kind.wireName: kind,
  };

  static SignalKind? fromWireName(String name) => _byWireName[name];
}

/// Every signal value is stored as a `DOUBLE`, including [SignalKind.ignition],
/// which uses 0.0 and 1.0.
///
/// The alternative — a nullable `BOOLEAN` column beside the numeric one — buys
/// type clarity in the schema and costs it everywhere else: every aggregate,
/// every roll-up and every "latest per signal" query would need to know which
/// column to read. One uniform numeric column keeps the log narrow and makes
/// compaction a single statement. The boolean meaning is restored in the domain
/// layer, which is where it belongs.
extension IgnitionValue on bool {
  double get asSignalValue => this ? 1.0 : 0.0;
}

extension IgnitionReading on double {
  /// Anything non-zero is "on". Tolerant on purpose: a vehicle reporting 1.0
  /// and one reporting 1 should not disagree.
  bool get asIgnition => this != 0.0;
}
