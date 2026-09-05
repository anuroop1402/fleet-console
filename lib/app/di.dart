/// Composition root. The only place concrete dependencies are constructed.
library;

import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/clock.dart';
import '../data/duckdb/fleet_database.dart';
import '../data/ingest/telemetry_ingestor.dart';

final GetIt locator = GetIt.instance;

/// Wires the app together. Called once, before `runApp`.
Future<void> configureDependencies({String? databasePath}) async {
  locator
    ..registerSingleton<Clock>(const SystemClock())
    ..registerSingleton<FleetDatabase>(
      await FleetDatabase.open(databasePath ?? await defaultDatabasePath()),
    );

  locator.registerSingleton<TelemetryIngestor>(
    TelemetryIngestor(
      database: locator<FleetDatabase>(),
      clock: locator<Clock>(),
    ),
  );
}

/// Where the database lives on device.
///
/// The application documents directory, so it is backed up and survives app
/// updates — the brief's local-first requirement is about the data outliving
/// the process, not the install.
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

/// True when the database file already exists, i.e. this is not a first run.
Future<bool> databaseExists(String path) async => File(path).exists();
