/// The app shell and its routes.
///
/// This is presentation, but it lives under `app/` because it is where BLoCs
/// are constructed from resolved use cases. Keeping the locator here means the
/// pages themselves receive their dependencies and stay testable without it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../data/devtools/fleet_simulator.dart';
import '../data/duckdb/fleet_database.dart';
import '../data/ingest/telemetry_ingestor.dart';
import '../domain/repositories/fleet_repository.dart';
import '../domain/usecases/get_fleet_list.dart';
import '../domain/usecases/evaluate_alerts.dart';
import '../domain/usecases/get_vehicle_detail.dart';
import '../domain/usecases/manage_alerts.dart';
import '../presentation/alerts/bloc/alerts_bloc.dart';
import '../presentation/alerts/view/alerts_page.dart';
import '../presentation/fleet/bloc/fleet_bloc.dart';
import '../presentation/fleet/view/fleet_page.dart';
import '../presentation/vehicle_detail/bloc/vehicle_detail_bloc.dart';
import '../presentation/vehicle_detail/view/vehicle_detail_page.dart';
import 'bootstrap.dart';
import 'di.dart';

class FleetConsoleApp extends StatelessWidget {
  const FleetConsoleApp({required this.processStart, super.key});

  /// When the process started, so startup can be measured honestly rather than
  /// from whenever the first widget happened to build.
  final DateTime processStart;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF1B7F4B));

    return MaterialApp(
      title: 'Fleet Console',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: scheme, useMaterial3: true),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1B7F4B),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: BootstrapGate(
        processStart: processStart,
        child: const _FleetRoute(),
      ),
    );
  }
}

class _FleetRoute extends StatelessWidget {
  const _FleetRoute();

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => FleetBloc(
      getFleetList: locator<GetFleetList>(),
      getStatusCounts: locator<GetFleetStatusCounts>(),
    )..add(const FleetRequested()),
    child: Builder(
      builder: (context) => FleetPage(
        onSeedData: _generateTelemetry,
        onAlertsTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => BlocProvider(
              create: (_) => AlertsBloc(
                getVisibleAlerts: locator<GetVisibleAlerts>(),
                dismissAlert: locator<DismissAlert>(),
                undoDismissal: locator<UndoAlertDismissal>(),
              )..add(const AlertsRequested()),
              child: const AlertsPage(),
            ),
          ),
        ),
        onVehicleTap: (vehicleId) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => BlocProvider(
              create: (_) => VehicleDetailBloc(
                getVehicleDetail: locator<GetVehicleDetail>(),
                getSocHistory: locator<GetSocHistory>(),
              )..add(VehicleDetailRequested(vehicleId)),
              child: const VehicleDetailPage(),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Seeds the register on first use, then emits one round of telemetry.
///
/// A debug affordance, not a product feature — it stands in for the packet feed
/// that a real deployment would receive over the network.
Future<void> _generateTelemetry() async {
  final simulator = locator<FleetSimulator>();
  final repository = locator<FleetRepository>();
  final ingestor = locator<TelemetryIngestor>();

  var fleet = simulator.vehicles(60);
  if (await repository.vehicleCount() == 0) {
    await repository.upsertVehicles(fleet);
  } else {
    fleet = simulator.vehicles(60);
  }

  await ingestor.ingest(simulator.currentRound(fleet));

  // Alerts are derived from readings, so they are re-evaluated as soon as new
  // readings land. Reads evaluate too, because some transitions are driven
  // purely by the clock rather than by a packet.
  await locator<EvaluateAlerts>()();

  // Fold the WAL in, so killing the app from the launcher right now still
  // leaves the data recoverable.
  await locator<FleetDatabase>().checkpoint();
}
