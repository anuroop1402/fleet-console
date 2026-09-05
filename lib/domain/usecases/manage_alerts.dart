/// Reading, dismissing and un-dismissing alerts.
library;

import '../../core/clock.dart';
import '../entities/alert.dart';
import '../entities/fleet_view.dart';
import '../repositories/alert_repository.dart';
import '../rules/alert_rules.dart';
import 'evaluate_alerts.dart';

/// The alerts a human should currently see.
///
/// Evaluates first, then reads. Some transitions are driven purely by the clock
/// — an alert goes stale with no new packet — so reading without evaluating
/// would show a confidently red pill for a reading nobody has seen in hours.
final class GetVisibleAlerts {
  const GetVisibleAlerts({
    required AlertRepository repository,
    required EvaluateAlerts evaluate,
  }) : _repository = repository,
       _evaluate = evaluate;

  final AlertRepository _repository;
  final EvaluateAlerts _evaluate;

  Future<List<AlertView>> call() async {
    await _evaluate();
    final alerts = await _repository.visibleAlerts();

    // Critical first, then oldest first within a severity. An operator working
    // down the list should meet the worst problem first, and among equals the
    // one that has been waiting longest.
    alerts.sort((a, b) {
      final bySeverity = b.alert.severity.rank.compareTo(a.alert.severity.rank);
      if (bySeverity != 0) return bySeverity;
      return a.alert.openedAt.compareTo(b.alert.openedAt);
    });
    return alerts;
  }
}

/// Records a human dismissing an alert.
///
/// The dismissal is persisted **immediately** rather than deferred for the
/// length of the undo window. If the app is killed mid-undo the alert stays
/// dismissed, which is the durable reading of what the user actually did — they
/// pressed dismiss, and the undo simply never happened.
final class DismissAlert {
  const DismissAlert({
    required AlertRepository repository,
    required Clock clock,
  }) : _repository = repository,
       _clock = clock;

  final AlertRepository _repository;
  final Clock _clock;

  Future<Alert> call(Alert alert, DismissalReason reason) async {
    final dismissed = dismiss(alert, reason, _clock.nowUtc());
    await _repository.saveDismissal(dismissed);
    return dismissed;
  }
}

/// Restores an alert dismissed within the undo window.
final class UndoAlertDismissal {
  const UndoAlertDismissal({
    required AlertRepository repository,
    required Clock clock,
  }) : _repository = repository,
       _clock = clock;

  final AlertRepository _repository;
  final Clock _clock;

  /// Returns the restored alert, or null when the window has closed.
  ///
  /// The window is checked here rather than trusted from the UI. A snackbar
  /// that is still on screen because the device was asleep is not a licence to
  /// rewrite a decision made ten minutes ago.
  Future<Alert?> call(Alert alert) async {
    if (!canUndo(alert, _clock.nowUtc())) return null;
    final restored = undoDismissal(alert);
    await _repository.saveDismissal(restored);
    return restored;
  }
}

/// Alert history for one vehicle, resolved instances included.
final class GetAlertHistory {
  const GetAlertHistory({required AlertRepository repository})
    : _repository = repository;

  final AlertRepository _repository;

  Future<List<Alert>> call(String vehicleId, {int limit = 50}) =>
      _repository.alertHistory(vehicleId, limit: limit);
}
