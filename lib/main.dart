/// Fleet Console — local-first telemetry over embedded DuckDB.
library;

import 'package:flutter/material.dart';

import 'app/app.dart';

void main() {
  // Captured before anything else, so "cold start" means process start rather
  // than "the moment we got around to measuring".
  final processStart = DateTime.now();

  WidgetsFlutterBinding.ensureInitialized();

  // runApp FIRST, and open the database behind a loading state.
  //
  // The previous version awaited configureDependencies() here. That produced a
  // blank white screen for as long as DuckDB took to open and replay its WAL —
  // observed at tens of seconds on the emulator after a force-stop, because
  // there is no Flutter UI at all until runApp is called. Opening a database
  // is not a reason to show the user nothing.
  runApp(FleetConsoleApp(processStart: processStart));
}
