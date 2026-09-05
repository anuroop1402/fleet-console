part of 'alerts_bloc.dart';

enum AlertsStatus { initial, loading, ready, failed }

final class AlertsState extends Equatable {
  const AlertsState({
    this.status = AlertsStatus.initial,
    this.alerts = const [],
    this.undoable,
    this.error,
  });

  final AlertsStatus status;
  final List<AlertView> alerts;

  /// The alert just dismissed, while its undo window is open.
  final Alert? undoable;

  final String? error;

  bool get isEmpty => status == AlertsStatus.ready && alerts.isEmpty;

  int get criticalCount => alerts
      .where((a) => a.alert.severity == AlertSeverity.critical)
      .length;

  AlertsState copyWith({
    AlertsStatus? status,
    List<AlertView>? alerts,
    Alert? undoable,
    String? error,
    bool clearUndoable = false,
    bool clearError = false,
  }) => AlertsState(
    status: status ?? this.status,
    alerts: alerts ?? this.alerts,
    undoable: clearUndoable ? null : (undoable ?? this.undoable),
    error: clearError ? null : (error ?? this.error),
  );

  @override
  List<Object?> get props => [status, alerts, undoable, error];
}
