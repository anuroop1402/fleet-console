/// Composition root. The only place concrete dependencies are constructed.
///
/// `test/architecture_test.dart` asserts that nothing in `domain/` or
/// `presentation/` imports get_it — a service locator reached from a widget is
/// a global variable with extra steps, and it makes the dependency graph
/// invisible.
library;

import 'package:get_it/get_it.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/clock.dart';
import '../data/devtools/fleet_simulator.dart';
import '../data/duckdb/fleet_database.dart';
import '../data/ingest/telemetry_ingestor.dart';
import '../data/repositories/duckdb_fleet_repository.dart';
import '../domain/repositories/fleet_repository.dart';
import '../domain/usecases/get_fleet_list.dart';
import '../domain/usecases/get_vehicle_detail.dart';

final GetIt locator = GetIt.instance;

/// Wires the app together. Called once, before `runApp`.
Future<void> configureDependencies({String? databasePath}) async {
  const clock = SystemClock();
  final database = await FleetDatabase.open(
    databasePath ?? await defaultDatabasePath(),
  );

  // The repository is registered behind its *interface*. Nothing above the
  // data layer can name DuckDbFleetRepository, so nothing above the data layer
  // can accidentally depend on it.
  final FleetRepository repository = DuckDbFleetRepository(database);

  locator
    ..registerSingleton<Clock>(clock)
    ..registerSingleton<FleetDatabase>(database)
    ..registerSingleton<FleetRepository>(repository)
    ..registerSingleton<TelemetryIngestor>(
      TelemetryIngestor(database: database, clock: clock),
    )
    ..registerSingleton<FleetSimulator>(FleetSimulator(clock: clock))
    ..registerSingleton<GetFleetList>(
      GetFleetList(repository: repository, clock: clock),
    )
    ..registerSingleton<GetFleetStatusCounts>(
      GetFleetStatusCounts(repository: repository, clock: clock),
    )
    ..registerSingleton<GetVehicleDetail>(
      GetVehicleDetail(repository: repository, clock: clock),
    )
    ..registerSingleton<GetSocHistory>(
      GetSocHistory(repository: repository, clock: clock),
    );
}

/// Where the database lives on device.
///
/// The application documents directory, so the data outlives the process and
/// survives app updates — which is what §2 of the brief actually asks for.
Future<String> defaultDatabasePath() async {
  final dir = await getApplicationDocumentsDirectory();
  return p.join(dir.path, 'fleet_console.duckdb');
}

Future<void> disposeDependencies() async {
  if (locator.isRegistered<FleetDatabase>()) {
    await locator<FleetDatabase>().dispose();
  }
  await locator.reset();
}
