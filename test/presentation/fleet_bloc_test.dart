/// Fleet list state transitions.
///
/// No database anywhere in this file. That is the layering working.
library;

import 'package:bloc_test/bloc_test.dart';
import 'package:fleet_console/core/clock.dart';
import 'package:fleet_console/domain/entities/fleet_view.dart';
import 'package:fleet_console/domain/entities/vehicle_status.dart';
import 'package:fleet_console/domain/usecases/get_fleet_list.dart';
import 'package:fleet_console/presentation/fleet/bloc/fleet_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_fleet_repository.dart';

void main() {
  late FakeFleetRepository repository;
  late FixedClock clock;
  final now = DateTime.utc(2026, 3, 1, 12);

  FleetListItem item(String id, VehicleStatus status) => FleetListItem(
    vehicleId: id,
    regNumber: 'KA01AB$id',
    model: 'Truck',
    status: status,
    soc: 55,
    socEventTs: now.subtract(const Duration(minutes: 1)),
    rangeKm: 180,
  );

  final fleet = [
    item('1', VehicleStatus.moving),
    item('2', VehicleStatus.moving),
    item('3', VehicleStatus.idle),
    item('4', VehicleStatus.stopped),
    item('5', VehicleStatus.offline),
    item('6', VehicleStatus.unknown),
  ];

  FleetBloc build() => FleetBloc(
    getFleetList: GetFleetList(repository: repository, clock: clock),
    getStatusCounts: GetFleetStatusCounts(
      repository: repository,
      clock: clock,
    ),
  );

  setUp(() {
    clock = FixedClock(now);
    repository = FakeFleetRepository(items: fleet);
  });

  group('loading', () {
    blocTest<FleetBloc, FleetState>(
      'goes loading then ready with items and counts',
      build: build,
      act: (bloc) => bloc.add(const FleetRequested()),
      expect: () => [
        isA<FleetState>().having((s) => s.status, 'status', FleetStatus.loading),
        isA<FleetState>()
            .having((s) => s.status, 'status', FleetStatus.ready)
            .having((s) => s.items.length, 'items', 6)
            .having((s) => s.totalVehicles, 'total', 6),
      ],
    );

    blocTest<FleetBloc, FleetState>(
      'counts include every status, zeroes included',
      build: build,
      act: (bloc) => bloc.add(const FleetRequested()),
      verify: (bloc) {
        // A chip that vanishes at zero makes the filter row jump about.
        expect(bloc.state.counts.keys, containsAll(VehicleStatus.values));
        expect(bloc.state.counts[VehicleStatus.moving], 2);
        expect(bloc.state.counts[VehicleStatus.idle], 1);
        expect(bloc.state.counts[VehicleStatus.unknown], 1);
      },
    );

    blocTest<FleetBloc, FleetState>(
      'reads the clock once per refresh, not once per query',
      build: build,
      act: (bloc) => bloc.add(const FleetRequested()),
      verify: (_) {
        // The list and the counts must be classified against the same instant,
        // or a vehicle on the ten-minute boundary can be counted online and
        // listed offline in the same frame.
        expect(repository.observedNows, hasLength(2));
        expect(repository.observedNows.toSet(), hasLength(1));
      },
    );
  });

  group('filtering', () {
    blocTest<FleetBloc, FleetState>(
      'narrows the list and remembers the filter',
      build: build,
      act: (bloc) => bloc.add(const FleetFilterChanged(VehicleStatus.moving)),
      verify: (bloc) {
        expect(bloc.state.filter, VehicleStatus.moving);
        expect(bloc.state.items, hasLength(2));
        expect(
          bloc.state.items.every((i) => i.status == VehicleStatus.moving),
          isTrue,
        );
      },
    );

    blocTest<FleetBloc, FleetState>(
      'counts stay whole-fleet while the list is filtered',
      build: build,
      act: (bloc) => bloc.add(const FleetFilterChanged(VehicleStatus.idle)),
      verify: (bloc) {
        // Otherwise every chip would read 0 or 1 as soon as one was selected.
        expect(bloc.state.items, hasLength(1));
        expect(bloc.state.totalVehicles, 6);
        expect(bloc.state.counts[VehicleStatus.moving], 2);
      },
    );

    blocTest<FleetBloc, FleetState>(
      'clearing the filter returns to All',
      build: build,
      act: (bloc) async {
        bloc.add(const FleetFilterChanged(VehicleStatus.moving));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const FleetFilterChanged(null));
      },
      verify: (bloc) {
        expect(bloc.state.filter, isNull);
        expect(bloc.state.items, hasLength(6));
      },
    );

    blocTest<FleetBloc, FleetState>(
      'a filter matching nothing is empty, not an error',
      build: () {
        repository.setItems([item('1', VehicleStatus.moving)]);
        return build();
      },
      act: (bloc) => bloc.add(const FleetFilterChanged(VehicleStatus.offline)),
      verify: (bloc) {
        expect(bloc.state.status, FleetStatus.ready);
        expect(bloc.state.isEmpty, isTrue);
        expect(bloc.state.error, isNull);
      },
    );
  });

  group('failure', () {
    blocTest<FleetBloc, FleetState>(
      'surfaces a read failure without losing the filter',
      build: () {
        repository.failWith = StateError('database is locked');
        return build();
      },
      act: (bloc) => bloc.add(const FleetFilterChanged(VehicleStatus.moving)),
      verify: (bloc) {
        expect(bloc.state.status, FleetStatus.failed);
        expect(bloc.state.error, contains('database is locked'));
        expect(bloc.state.filter, VehicleStatus.moving);
      },
    );

    blocTest<FleetBloc, FleetState>(
      'a retry after a failure recovers',
      build: () {
        repository.failWith = StateError('transient');
        return build();
      },
      act: (bloc) async {
        bloc.add(const FleetRequested());
        await Future<void>.delayed(Duration.zero);
        repository.failWith = null;
        bloc.add(const FleetRequested());
      },
      verify: (bloc) {
        expect(bloc.state.status, FleetStatus.ready);
        expect(bloc.state.error, isNull);
        expect(bloc.state.items, hasLength(6));
      },
    );
  });

  group('empty fleet', () {
    blocTest<FleetBloc, FleetState>(
      'an empty fleet is ready and empty',
      build: () {
        repository.setItems([]);
        return build();
      },
      act: (bloc) => bloc.add(const FleetRequested()),
      verify: (bloc) {
        expect(bloc.state.status, FleetStatus.ready);
        expect(bloc.state.isEmpty, isTrue);
        expect(bloc.state.totalVehicles, 0);
      },
    );
  });
}
