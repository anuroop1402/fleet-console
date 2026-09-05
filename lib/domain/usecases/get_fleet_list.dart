/// Fleet list and filter counts.
library;

import '../../core/clock.dart';
import '../entities/fleet_view.dart';
import '../entities/vehicle_status.dart';
import '../repositories/fleet_repository.dart';

/// Loads the fleet list, optionally filtered by status.
///
/// Thin by design, and kept rather than inlined. Its job is to own the clock:
/// "now" is read exactly once here and passed down, so every row in a single
/// refresh is classified against the same instant. Letting the repository read
/// the clock per query would let a vehicle be OFFLINE in the list and online in
/// the count computed a millisecond later.
final class GetFleetList {
  const GetFleetList({
    required FleetRepository repository,
    required Clock clock,
  }) : _repository = repository,
       _clock = clock;

  final FleetRepository _repository;
  final Clock _clock;

  Future<List<FleetListItem>> call({VehicleStatus? status}) =>
      _repository.fleetList(now: _clock.nowUtc(), status: status);
}

/// Live counts for the filter chips.
final class GetFleetStatusCounts {
  const GetFleetStatusCounts({
    required FleetRepository repository,
    required Clock clock,
  }) : _repository = repository,
       _clock = clock;

  final FleetRepository _repository;
  final Clock _clock;

  /// Counts for every chip, including zeroes.
  ///
  /// The repository only returns statuses that occur, but a chip reading
  /// "Moving" with no number looks broken, and one that disappears when the
  /// count hits zero makes the row jump about. Filling the gaps is a
  /// presentation concern that every caller would otherwise repeat.
  Future<Map<VehicleStatus, int>> call() async {
    final counts = await _repository.statusCounts(now: _clock.nowUtc());
    return {
      for (final status in VehicleStatus.values) status: counts[status] ?? 0,
    };
  }
}
