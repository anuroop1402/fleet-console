/// The app shell.
///
/// Phase 1 ships a diagnostics home screen rather than a placeholder: it reads
/// live counts out of DuckDB, which is the end-to-end proof that the ingest
/// path and the read path work on a real device. The fleet list replaces it in
/// Phase 3.
library;

import 'package:flutter/material.dart';

import '../data/duckdb/fleet_database.dart';
import 'di.dart';

class FleetConsoleApp extends StatelessWidget {
  const FleetConsoleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Fleet Console',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.teal,
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: const DatabaseStatusPage(),
  );
}

/// Reads straight from DuckDB. No in-memory list shadowing it — that is the
/// architectural requirement in §2 of the brief, and it starts here.
class DatabaseStatusPage extends StatefulWidget {
  const DatabaseStatusPage({super.key});

  @override
  State<DatabaseStatusPage> createState() => _DatabaseStatusPageState();
}

class _DatabaseStatusPageState extends State<DatabaseStatusPage> {
  late Future<List<(String, int)>> _counts;

  @override
  void initState() {
    super.initState();
    _counts = _loadCounts();
  }

  Future<List<(String, int)>> _loadCounts() async {
    final db = locator<FleetDatabase>();
    const tables = [
      'vehicles',
      'signal_readings',
      'location_fixes',
      'latest_readings',
      'rejected_packets',
    ];

    final counts = <(String, int)>[];
    for (final table in tables) {
      final result = await db.connection.query('SELECT COUNT(*) FROM $table');
      final value = result.fetchAll().first.first;
      await result.dispose();
      counts.add((table, value is BigInt ? value.toInt() : value! as int));
    }
    return counts;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Fleet Console'),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: () => setState(() => _counts = _loadCounts()),
        ),
      ],
    ),
    body: FutureBuilder<List<(String, int)>>(
      future: _counts,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('${snapshot.error}'),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final rows = snapshot.data!;
        return ListView(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Read live from the on-device DuckDB database.',
                style: TextStyle(fontStyle: FontStyle.italic),
              ),
            ),
            for (final (table, count) in rows)
              ListTile(
                dense: true,
                title: Text(table, style: const TextStyle(fontFamily: 'monospace')),
                trailing: Text(
                  '$count',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                locator<FleetDatabase>().path,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ],
        );
      },
    ),
  );
}
