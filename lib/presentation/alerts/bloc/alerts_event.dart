part of 'alerts_bloc.dart';

sealed class AlertsEvent extends Equatable {
  const AlertsEvent();

  @override
  List<Object?> get props => [];
}

final class AlertsRequested extends AlertsEvent {
  const AlertsRequested();
}

final class AlertDismissed extends AlertsEvent {
  const AlertDismissed(this.alert, this.reason);

  final Alert alert;
  final DismissalReason reason;

  @override
  List<Object?> get props => [alert, reason];
}

final class AlertDismissalUndone extends AlertsEvent {
  const AlertDismissalUndone();
}
