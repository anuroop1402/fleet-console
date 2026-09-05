part of 'fleet_bloc.dart';

sealed class FleetEvent extends Equatable {
  const FleetEvent();

  @override
  List<Object?> get props => [];
}

/// Load, or reload after ingest.
final class FleetRequested extends FleetEvent {
  const FleetRequested();
}

/// A filter chip was tapped. Null means "All".
final class FleetFilterChanged extends FleetEvent {
  const FleetFilterChanged(this.status);

  final VehicleStatus? status;

  @override
  List<Object?> get props => [status];
}
