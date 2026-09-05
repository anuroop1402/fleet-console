part of 'vehicle_detail_bloc.dart';

enum DetailStatus { initial, loading, ready, notFound, failed }

final class VehicleDetailState extends Equatable {
  const VehicleDetailState({
    this.status = DetailStatus.initial,
    this.detail,
    this.socHistory = const [],
    this.error,
  });

  final DetailStatus status;
  final VehicleDetail? detail;

  /// May be empty for a vehicle that has reported no SOC in the retained
  /// window. That is a legitimate answer, not an error.
  final List<SocSample> socHistory;

  final String? error;

  VehicleDetailState copyWith({
    DetailStatus? status,
    VehicleDetail? detail,
    List<SocSample>? socHistory,
    String? error,
    bool clearError = false,
  }) => VehicleDetailState(
    status: status ?? this.status,
    detail: detail ?? this.detail,
    socHistory: socHistory ?? this.socHistory,
    error: clearError ? null : (error ?? this.error),
  );

  @override
  List<Object?> get props => [status, detail, socHistory, error];
}
