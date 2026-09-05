/// Alerts list, dismissal and undo.
library;

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

import '../../../domain/entities/alert.dart';
import '../../../domain/entities/fleet_view.dart';
import '../../../domain/usecases/manage_alerts.dart';

part 'alerts_event.dart';
part 'alerts_state.dart';

final class AlertsBloc extends Bloc<AlertsEvent, AlertsState> {
  AlertsBloc({
    required GetVisibleAlerts getVisibleAlerts,
    required DismissAlert dismissAlert,
    required UndoAlertDismissal undoDismissal,
  }) : _getVisibleAlerts = getVisibleAlerts,
       _dismissAlert = dismissAlert,
       _undoDismissal = undoDismissal,
       super(const AlertsState()) {
    on<AlertsRequested>(_onRequested);
    on<AlertDismissed>(_onDismissed);
    on<AlertDismissalUndone>(_onUndone);
  }

  final GetVisibleAlerts _getVisibleAlerts;
  final DismissAlert _dismissAlert;
  final UndoAlertDismissal _undoDismissal;

  Future<void> _onRequested(
    AlertsRequested event,
    Emitter<AlertsState> emit,
  ) async {
    emit(state.copyWith(status: AlertsStatus.loading, clearError: true));
    try {
      emit(
        state.copyWith(
          status: AlertsStatus.ready,
          alerts: await _getVisibleAlerts(),
        ),
      );
    } on Object catch (error) {
      emit(state.copyWith(status: AlertsStatus.failed, error: '$error'));
    }
  }

  Future<void> _onDismissed(
    AlertDismissed event,
    Emitter<AlertsState> emit,
  ) async {
    try {
      // Persisted immediately, not deferred for the undo window. If the app
      // dies mid-undo the alert stays dismissed, which is the durable reading
      // of what the user actually did.
      final dismissed = await _dismissAlert(event.alert, event.reason);

      emit(
        state.copyWith(
          alerts: state.alerts
              .where((a) => !_sameInstance(a.alert, event.alert))
              .toList(),
          // Drives the UNDO snackbar. Cleared once the window closes so a
          // stale snackbar cannot rewrite an old decision.
          undoable: dismissed,
        ),
      );
    } on Object catch (error) {
      emit(state.copyWith(status: AlertsStatus.failed, error: '$error'));
    }
  }

  Future<void> _onUndone(
    AlertDismissalUndone event,
    Emitter<AlertsState> emit,
  ) async {
    final target = state.undoable;
    if (target == null) return;

    try {
      // Null means the five seconds elapsed. The use case checks the window
      // rather than trusting the UI: a snackbar still on screen because the
      // device slept is not a licence to undo a ten-minute-old decision.
      final restored = await _undoDismissal(target);
      emit(state.copyWith(clearUndoable: true));
      if (restored != null) add(const AlertsRequested());
    } on Object catch (error) {
      emit(state.copyWith(status: AlertsStatus.failed, error: '$error'));
    }
  }

  static bool _sameInstance(Alert a, Alert b) =>
      a.vehicleId == b.vehicleId &&
      a.kind == b.kind &&
      a.openedAt == b.openedAt;
}
