/// The pill beside each row of the readings register.
library;

/// Four outcomes, and the distinction between the last two is the point.
///
/// The brief is precise here: STALE is "too old to judge, **no** normal/alert
/// claim". It is not a third severity — it is a refusal to answer. And a signal
/// that has never reported is a different fact again: we are not declining to
/// judge an old value, there is no value.
enum Verdict {
  /// Fresh, and inside its threshold.
  normal,

  /// Fresh, and outside its threshold.
  alert,

  /// Seen, but too old to make any claim about. Rendered grey.
  stale,

  /// Never reported. Rendered as "—" with no pill at all.
  neverReported;

  /// Whether this verdict asserts anything about the vehicle's condition.
  ///
  /// Used by the alert engine: thresholds apply to fresh readings only, so a
  /// stale SOC of 5% raises nothing — but it does not resolve anything either.
  bool get isClaim => this == Verdict.normal || this == Verdict.alert;

  /// Whether a pill is drawn at all.
  bool get hasPill => this != Verdict.neverReported;
}
