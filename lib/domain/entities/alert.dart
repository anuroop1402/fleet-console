/// Alerts, their severity, and what a human did about them.
library;

import 'package:equatable/equatable.dart';

/// What kind of problem this is.
///
/// The brief lists three alerts but says the two SOC ones "are one escalating
/// alert, not two". So SOC is a *single kind* whose severity moves, rather than
/// two kinds that can both be open at once. Getting this wrong shows up as two
/// battery rows on one vehicle, which is the visible symptom of the wrong
/// model underneath.
enum AlertKind {
  batterySoc('battery_soc'),
  batteryOverheating('battery_overheating');

  const AlertKind(this.wireName);

  /// Stored in the database, so it is part of the on-disk format.
  final String wireName;
}

enum AlertSeverity {
  warning('warning', 1),
  critical('critical', 2);

  const AlertSeverity(this.wireName, this.rank);

  final String wireName;

  /// Higher is worse. Ordering matters: a dismissal is only overridden by an
  /// *escalation*, so severities have to be comparable rather than just equal
  /// or not.
  final int rank;

  bool isWorseThan(AlertSeverity other) => rank > other.rank;
}

/// The three options on the dismissal sheet, in the order the brief specifies.
enum DismissalReason {
  onIt('on_it', 'I am on it'),
  wrongAlert('wrong_alert', 'Wrong alert'),
  somethingElse('something_else', 'Something else…');

  const DismissalReason(this.wireName, this.label);

  final String wireName;
  final String label;
}

/// One open alert instance.
///
/// Identity is `(vehicleId, kind, openedAt)`. A condition that clears and later
/// re-fires produces a *new* instance with a new [openedAt] — not a revival of
/// the old one — because a new occurrence deserves a fresh decision from
/// whoever is watching.
final class Alert extends Equatable {
  const Alert({
    required this.vehicleId,
    required this.kind,
    required this.severity,
    required this.openedAt,
    this.dismissedAt,
    this.dismissedAtSeverity,
    this.dismissalReason,
    this.isConditionStale = false,
    this.lastKnownValue,
    this.lastKnownAt,
  });

  final String vehicleId;
  final AlertKind kind;

  /// Tracks the *current* condition, so it de-escalates as well as escalates.
  final AlertSeverity severity;

  final DateTime openedAt;

  final DateTime? dismissedAt;

  /// The severity the human was looking at when they dismissed it.
  ///
  /// This is the field that makes re-escalation work. Silencing a warning is
  /// not consent to silence a critical, so a dismissal only holds while the
  /// condition stays at or below the severity it was dismissed at.
  final AlertSeverity? dismissedAtSeverity;

  final DismissalReason? dismissalReason;

  /// The reading behind this alert has gone stale.
  ///
  /// The alert stays *open*. Resolving it would assert the condition cleared,
  /// and we cannot see that. Staying silent about a possibly-burning truck is
  /// the worse error, so it stays visible and says plainly that it is unsure.
  final bool isConditionStale;

  /// What we last saw, and when — so a stale alert can say "last known 8% at
  /// 14:02" instead of showing nothing.
  final double? lastKnownValue;
  final DateTime? lastKnownAt;

  bool get isDismissed => dismissedAt != null;

  /// Whether this alert should appear in the alerts list.
  bool get isVisible => !isDismissed;

  Alert copyWith({
    AlertSeverity? severity,
    DateTime? dismissedAt,
    AlertSeverity? dismissedAtSeverity,
    DismissalReason? dismissalReason,
    bool? isConditionStale,
    double? lastKnownValue,
    DateTime? lastKnownAt,
    bool clearDismissal = false,
  }) => Alert(
    vehicleId: vehicleId,
    kind: kind,
    severity: severity ?? this.severity,
    openedAt: openedAt,
    dismissedAt: clearDismissal ? null : (dismissedAt ?? this.dismissedAt),
    dismissedAtSeverity: clearDismissal
        ? null
        : (dismissedAtSeverity ?? this.dismissedAtSeverity),
    dismissalReason: clearDismissal
        ? null
        : (dismissalReason ?? this.dismissalReason),
    isConditionStale: isConditionStale ?? this.isConditionStale,
    lastKnownValue: lastKnownValue ?? this.lastKnownValue,
    lastKnownAt: lastKnownAt ?? this.lastKnownAt,
  );

  @override
  List<Object?> get props => [
    vehicleId,
    kind,
    severity,
    openedAt,
    dismissedAt,
    dismissedAtSeverity,
    dismissalReason,
    isConditionStale,
    lastKnownValue,
    lastKnownAt,
  ];
}
