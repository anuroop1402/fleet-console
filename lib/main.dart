/// Fleet Console — local-first telemetry over embedded DuckDB.
library;

import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/di.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureDependencies();
  runApp(const FleetConsoleApp());
}
