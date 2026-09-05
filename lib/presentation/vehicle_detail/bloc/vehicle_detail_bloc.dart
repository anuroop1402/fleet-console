/// Vehicle detail state: the readings register plus SOC history.
library;

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

import '../../../domain/entities/fleet_view.dart';
import '../../../domain/usecases/get_vehicle_detail.dart';

part 'vehicle_detail_event.dart';
part 'vehicle_detail_state.dart';

final class VehicleDetailBloc
    extends Bloc<VehicleDetailEvent, VehicleDetailState> {
  VehicleDetailBloc({
    required GetVehicleDetail getVehicleDetail,
    required GetSocHistory getSocHistory,
  }) : _getVehicleDetail = getVehicleDetail,
       _getSocHistory = getSocHistory,
       super(const VehicleDetailState()) {
    on<VehicleDetailRequested>(_onRequested);
  }

  final GetVehicleDetail _getVehicleDetail;
  final GetSocHistory _getSocHistory;

  Future<void> _onRequested(
    VehicleDetailRequested event,
    Emitter<VehicleDetailState> emit,
  ) async {
    emit(state.copyWith(status: DetailStatus.loading, clearError: true));

    try {
      final detail = await _getVehicleDetail(event.vehicleId);
      if (detail == null) {
        emit(state.copyWith(status: DetailStatus.notFound));
        return;
      }

      // History is secondary: a vehicle with a readable register but no SOC
      // history is still worth showing. Failing the whole screen because the
      // chart query failed would be the wrong trade.
      final history = await _getSocHistory(event.vehicleId);

      emit(
        state.copyWith(
          status: DetailStatus.ready,
          detail: detail,
          socHistory: history,
        ),
      );
    } on Object catch (error) {
      emit(state.copyWith(status: DetailStatus.failed, error: '$error'));
    }
  }
}
