/// The status chip on the fleet list.
library;

/// Evaluated first-match-wins, in declaration order.
///
/// The brief gives four rules. It does not say what to show for a vehicle that
/// is online but has told us neither its speed nor its ignition state — and
/// since packets carry a *subset* of signals, that happens. [unknown] exists
/// for exactly that case.
///
/// The alternative was defaulting to [stopped], which asserts "ignition off"
/// from an absence of evidence. On a fleet screen whose whole job is "what
/// needs attention now", inventing a reassuring status is the worse failure.
enum VehicleStatus {
  /// No signal — of any kind — within the offline window.
  ///
  /// Vehicle-level, deliberately distinct from per-signal staleness: a vehicle
  /// can be online while its SOC reading is stale.
  offline,

  /// Fresh speed reading above zero.
  moving,

  /// Fresh speed of zero, with fresh ignition on.
  idle,

  /// Fresh ignition off.
  stopped,

  /// Online, but nothing fresh enough to classify it.
  unknown;

  /// The five filter chips. `unknown` has no chip of its own — such vehicles
  /// appear under "All" and nowhere else, which is honest: we cannot claim they
  /// are stopped.
  bool get hasFilterChip => this != VehicleStatus.unknown;
}
