part of 'vehicle_detail_bloc.dart';

sealed class VehicleDetailEvent extends Equatable {
  const VehicleDetailEvent();

  @override
  List<Object?> get props => [];
}

final class VehicleDetailRequested extends VehicleDetailEvent {
  const VehicleDetailRequested(this.vehicleId);

  final String vehicleId;

  @override
  List<Object?> get props => [vehicleId];
}
