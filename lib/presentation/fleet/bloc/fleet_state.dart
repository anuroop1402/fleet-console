part of 'fleet_bloc.dart';

enum FleetStatus { initial, loading, ready, failed }

/// One state object rather than an `isLoading` + `error` + `data` triple.
///
/// A triple permits states that cannot happen — loading *and* failed, data
/// *and* an error — and every widget then has to decide which wins. A single
/// enum plus its payload makes the impossible combinations unrepresentable.
final class FleetState extends Equatable {
  const FleetState({
    this.status = FleetStatus.initial,
    this.items = const [],
    this.counts = const {},
    this.filter,
    this.error,
  });

  final FleetStatus status;
  final List<FleetListItem> items;

  /// Every status, including zeroes, so chips do not appear and vanish.
  final Map<VehicleStatus, int> counts;

  /// Null means "All".
  final VehicleStatus? filter;

  final String? error;

  /// Loaded successfully, but this filter matches nothing. Distinct from
  /// "still loading" — the brief asks for an explicit empty state.
  bool get isEmpty => status == FleetStatus.ready && items.isEmpty;

  int get totalVehicles =>
      counts.values.fold(0, (sum, count) => sum + count);

  FleetState copyWith({
    FleetStatus? status,
    List<FleetListItem>? items,
    Map<VehicleStatus, int>? counts,
    VehicleStatus? filter,
    String? error,
    bool clearFilter = false,
    bool clearError = false,
  }) => FleetState(
    status: status ?? this.status,
    items: items ?? this.items,
    counts: counts ?? this.counts,
    filter: clearFilter ? null : (filter ?? this.filter),
    error: clearError ? null : (error ?? this.error),
  );

  @override
  List<Object?> get props => [status, items, counts, filter, error];
}
