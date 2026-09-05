/// Fleet list state.
///
/// Depends on use cases only. It has no idea DuckDB exists, which is what lets
/// it be tested with a fake repository and no native library —
/// `test/architecture_test.dart` enforces that.
library;

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

import '../../../domain/entities/fleet_view.dart';
import '../../../domain/entities/vehicle_status.dart';
import '../../../domain/usecases/get_fleet_list.dart';

part 'fleet_event.dart';
part 'fleet_state.dart';

final class FleetBloc extends Bloc<FleetEvent, FleetState> {
  FleetBloc({
    required GetFleetList getFleetList,
    required GetFleetStatusCounts getStatusCounts,
  }) : _getFleetList = getFleetList,
       _getStatusCounts = getStatusCounts,
       super(const FleetState()) {
    on<FleetRequested>(_onRequested);
    on<FleetFilterChanged>(_onFilterChanged);
  }

  final GetFleetList _getFleetList;
  final GetFleetStatusCounts _getStatusCounts;

  Future<void> _onRequested(
    FleetRequested event,
    Emitter<FleetState> emit,
  ) => _load(emit, state.filter);

  Future<void> _onFilterChanged(
    FleetFilterChanged event,
    Emitter<FleetState> emit,
  ) => _load(emit, event.status, filterChanged: true);

  Future<void> _load(
    Emitter<FleetState> emit,
    VehicleStatus? filter, {
    bool filterChanged = false,
  }) async {
    emit(
      state.copyWith(
        status: FleetStatus.loading,
        filter: filter,
        clearFilter: filterChanged && filter == null,
        clearError: true,
      ),
    );

    try {
      // Both in flight together. Sequential would let the list and the chip
      // counts be computed against clocks milliseconds apart, which is enough
      // for a vehicle on the ten-minute boundary to be counted as online and
      // listed as offline in the same frame.
      final results = await Future.wait([
        _getFleetList(status: filter),
        _getStatusCounts(),
      ]);

      emit(
        state.copyWith(
          status: FleetStatus.ready,
          items: results[0] as List<FleetListItem>,
          counts: results[1] as Map<VehicleStatus, int>,
        ),
      );
    } on Object catch (error) {
      emit(state.copyWith(status: FleetStatus.failed, error: '$error'));
    }
  }
}
