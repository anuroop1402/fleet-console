/// PHASE 0 SPIKE — throwaway.
///
/// This file exists to answer one question before any architecture is built on
/// top of DuckDB: **does an embedded, file-backed DuckDB database actually work
/// on the target devices, and does it survive the app being killed?**
///
/// The brief's §2 makes local-first persistence a hard requirement. If this
/// spike fails on a platform, that platform is dropped and the failure is
/// reported — it is not worked around.
///
/// Every check below produces evidence that lands in docs/. Replaced entirely
/// in Phase 1.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() {
  // Captured as early as possible so "cold start" means process start, not
  // widget-tree start. Phase 6 needs this to be honest.
  final processStart = DateTime.now();
  WidgetsFlutterBinding.ensureInitialized();
  runApp(SpikeApp(processStart: processStart));
}

/// Runs [_isolateProbe] on a background isolate.
///
/// This has to be a top-level function taking the transferable as its only
/// argument. A closure written inline inside a `State` method captures the
/// enclosing *context*, which includes `this` — and `Isolate.run` then tries to
/// send the entire widget tree, failing with "object is unsendable". Learned
/// the hard way; see docs/04.
Future<int> _spawnProbe(TransferableDatabase td) =>
    Isolate.run(() => _isolateProbe(td));

Future<int> _isolateProbe(TransferableDatabase td) async {
  final conn = await duckdb.connectWithTransferred(td);
  try {
    await conn.execute(
      'CREATE OR REPLACE TABLE isolate_probe AS '
      'SELECT i AS id FROM range(50000) t(i)',
    );
    final result = await conn.query('SELECT COUNT(*) FROM isolate_probe');
    final rows = result.fetchAll();
    await result.dispose();
    final v = rows.first.first;
    return v is BigInt ? v.toInt() : v as int;
  } finally {
    await conn.dispose();
  }
}

/// One diagnostic result. [ok] == null means "informational, not a pass/fail".
class Check {
  Check(this.name, this.detail, {this.ok});

  final String name;
  final String detail;
  final bool? ok;
}

class SpikeApp extends StatelessWidget {
  const SpikeApp({required this.processStart, super.key});

  final DateTime processStart;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'DuckDB Spike',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: SpikePage(processStart: processStart),
  );
}

class SpikePage extends StatefulWidget {
  const SpikePage({required this.processStart, super.key});

  final DateTime processStart;

  @override
  State<SpikePage> createState() => _SpikePageState();
}

class _SpikePageState extends State<SpikePage> {
  final List<Check> _checks = <Check>[];
  bool _running = true;
  String? _fatal;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void _add(String name, String detail, {bool? ok}) {
    // Also to stdout, so a headless run captures the same evidence the UI shows.
    final tag = switch (ok) { true => 'PASS', false => 'FAIL', null => 'INFO' };
    stdout.writeln('[SPIKE] $tag  $name');
    for (final line in detail.split('\n')) {
      stdout.writeln('[SPIKE]       $line');
    }
    if (!mounted) return;
    setState(() => _checks.add(Check(name, detail, ok: ok)));
  }

  /// Reads a single scalar. DuckDB hands back `int` for BIGINT but `BigInt` for
  /// UBIGINT/HUGEINT, so callers normalise via [_asInt].
  Future<Object?> _scalar(Connection conn, String sql) async {
    final result = await conn.query(sql);
    try {
      final rows = result.fetchAll();
      if (rows.isEmpty || rows.first.isEmpty) return null;
      return rows.first.first;
    } finally {
      await result.dispose();
    }
  }

  int _asInt(Object? v) => switch (v) {
    final int i => i,
    final BigInt b => b.toInt(),
    final double d => d.toInt(),
    _ => -1,
  };

  Future<void> _run() async {
    Database? db;
    Connection? conn;
    try {
      // ---------------------------------------------------------------- 1
      _add('Platform', '${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
      _add('Device timezone', '${DateTime.now().timeZoneName} '
          '(offset ${DateTime.now().timeZoneOffset})');

      // ---------------------------------------------------------------- 2
      // Loading the native library at all is the first thing that can fail:
      // on Android this is the ~66 MB libduckdb.so, arm64-v8a only.
      final version = duckdb.version;
      _add('Native library loaded', 'DuckDB $version', ok: true);

      // ---------------------------------------------------------------- 3
      final dir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(dir.path, 'spike.duckdb');
      final existedBefore = File(dbPath).existsSync();
      _add(
        'Database file',
        '$dbPath\nexisted before this launch: $existedBefore',
      );

      final openWatch = Stopwatch()..start();
      db = await duckdb.open(dbPath);
      conn = await duckdb.connect(db);
      openWatch.stop();
      _add('open() + connect()', '${openWatch.elapsedMilliseconds} ms', ok: true);

      // ---------------------------------------------------------------- 4
      // THE PERSISTENCE TEST.
      //
      // Every launch appends one row. If the count climbs across a force-stop
      // and relaunch, data genuinely came back off disk. Note there is NO
      // `DEFAULT CURRENT_TIMESTAMP` here: a function-valued default is reported
      // to crash WAL replay on Android (upstream #35), and the app supplies
      // timestamps from an injected clock anyway.
      await conn.execute('''
        CREATE TABLE IF NOT EXISTS launch_log (
          launch_id   BIGINT,
          launched_at TIMESTAMP
        )
      ''');
      final priorLaunches = _asInt(
        await _scalar(conn, 'SELECT COUNT(*) FROM launch_log'),
      );

      final stmt = await conn.prepare(
        'INSERT INTO launch_log VALUES (?, ?)',
      );
      stmt.bind(priorLaunches + 1, 1);
      // Bound as UTC. DuckDB TIMESTAMP is timezone-naive and this binding
      // stores microsecondsSinceEpoch, so a local DateTime would silently
      // shift. Project rule: always .toUtc().
      stmt.bind(DateTime.now().toUtc(), 2);
      final insertResult = await stmt.execute();
      await insertResult.dispose();
      await stmt.dispose();

      final nowLaunches = _asInt(
        await _scalar(conn, 'SELECT COUNT(*) FROM launch_log'),
      );
      _add(
        'PERSISTENCE — launch counter',
        'rows found at startup: $priorLaunches\n'
            'rows after this launch: $nowLaunches\n'
            '${priorLaunches > 0 ? "PROVEN: data survived a previous process death." : "First launch. Force-stop the app and reopen to prove persistence."}',
        ok: nowLaunches == priorLaunches + 1,
      );

      // ---------------------------------------------------------------- 5
      // Timestamp round-trip. This is the trap the research flagged: binding a
      // LOCAL DateTime from IST stores a value 5h30m earlier.
      final localNoon = DateTime(2026, 1, 1, 12);
      final utcNoon = DateTime.utc(2026, 1, 1, 12);
      await conn.execute('CREATE OR REPLACE TABLE ts_probe (kind VARCHAR, t TIMESTAMP)');
      final tsStmt = await conn.prepare('INSERT INTO ts_probe VALUES (?, ?)');
      tsStmt.bind('local', 1);
      tsStmt.bind(localNoon, 2);
      await (await tsStmt.execute()).dispose();
      tsStmt.clearBinding();
      tsStmt.bind('utc', 1);
      tsStmt.bind(utcNoon, 2);
      await (await tsStmt.execute()).dispose();
      await tsStmt.dispose();

      final tsResult = await conn.query('SELECT kind, t FROM ts_probe ORDER BY kind');
      final tsRows = tsResult.fetchAll();
      await tsResult.dispose();
      final readBack = <String, Object?>{
        for (final r in tsRows) r[0]! as String: r[1],
      };
      final utcRt = readBack['utc'] as DateTime?;
      _add(
        'Timestamp round-trip',
        'bound local  DateTime(2026,1,1,12:00) -> read back ${readBack['local']}\n'
            'bound utc DateTime.utc(2026,1,1,12:00) -> read back ${readBack['utc']}\n'
            'read-back isUtc: ${utcRt?.isUtc}\n'
            'CONFIRMS: bind .toUtc() everywhere, or values shift by the device offset.',
        ok: utcRt == utcNoon,
      );

      // ---------------------------------------------------------------- 6
      // core_functions must be statically linked — there is no extension repo
      // for Android, so if trig is missing, haversine in SQL is impossible.
      final fnCount = _asInt(await _scalar(
        conn,
        "SELECT COUNT(*) FROM duckdb_functions() "
        "WHERE function_name IN ('sin','cos','asin','sqrt','radians','atan2')",
      ));
      final radians180 = await _scalar(conn, 'SELECT radians(180)');
      _add(
        'core_functions (math) available',
        'matched 6 of: sin cos asin sqrt radians atan2 -> found $fnCount\n'
            'radians(180) = $radians180',
        ok: fnCount == 6,
      );

      // Spatial is expected to be ABSENT on Android. Confirm, don't assume.
      var spatialNote = 'not attempted';
      try {
        await conn.execute('LOAD spatial');
        spatialNote = 'LOADED — unexpected on Android';
      } on Object catch (e) {
        spatialNote = 'unavailable (expected on Android): '
            '${e.toString().split('\n').first}';
      }
      _add('spatial extension', spatialNote);

      // ---------------------------------------------------------------- 7
      // Bulk generation entirely in-engine. This is the 2M-row strategy: one
      // execute(), zero FFI row crossings.
      const bulkRows = 2000000;
      final bulkWatch = Stopwatch()..start();
      await conn.execute('''
        CREATE OR REPLACE TABLE bulk AS
        SELECT
          i                                              AS id,
          (i % 500)                                      AS vehicle_id,
          TIMESTAMP '2026-01-01 00:00:00' + INTERVAL (i) SECOND AS event_ts,
          (i % 101)::DOUBLE                              AS value
        FROM range($bulkRows) t(i)
      ''');
      bulkWatch.stop();
      final bulkCount = _asInt(await _scalar(conn, 'SELECT COUNT(*) FROM bulk'));
      _add(
        'Bulk generation via range()',
        '$bulkCount rows in ${bulkWatch.elapsedMilliseconds} ms '
            '(${(bulkCount / (bulkWatch.elapsedMilliseconds / 1000)).round()} rows/sec)',
        ok: bulkCount == bulkRows,
      );

      // ---------------------------------------------------------------- 8
      // A representative "fleet list" shape over the full log: latest row per
      // vehicle via a window function. This is the NAIVE query Phase 6 reports
      // as the "before" number.
      final naiveWatch = Stopwatch()..start();
      final naiveCount = _asInt(await _scalar(conn, '''
        SELECT COUNT(*) FROM (
          SELECT vehicle_id, value,
                 ROW_NUMBER() OVER (PARTITION BY vehicle_id ORDER BY event_ts DESC) AS rn
          FROM bulk
        ) WHERE rn = 1
      '''));
      naiveWatch.stop();
      _add(
        'Naive latest-per-vehicle over 2M rows',
        '$naiveCount vehicles in ${naiveWatch.elapsedMilliseconds} ms\n'
            'This is the number the materialised projection has to beat.',
        ok: naiveCount == 500,
      );

      // ---------------------------------------------------------------- 9
      // Window functions / QUALIFY / ASOF are core-engine features the design
      // leans on. Prove they parse and run here, not in Phase 5.
      try {
        final q = _asInt(await _scalar(conn, '''
          SELECT COUNT(*) FROM (
            SELECT vehicle_id, event_ts,
                   LAG(value) OVER (PARTITION BY vehicle_id ORDER BY event_ts) AS prev
            FROM bulk WHERE vehicle_id < 5
            QUALIFY ROW_NUMBER() OVER (PARTITION BY vehicle_id ORDER BY event_ts DESC) = 1
          )
        '''));
        _add('LAG + QUALIFY', 'returned $q rows', ok: q == 5);
      } on Object catch (e) {
        _add('LAG + QUALIFY', 'FAILED: $e', ok: false);
      }

      // ---------------------------------------------------------------- 10
      // Background isolate via TransferableDatabase. The backfill and the
      // replay coordinator both depend on this working.
      try {
        final transferable = db.transferable;
        final isolateWatch = Stopwatch()..start();
        final fromIsolate = await _spawnProbe(transferable);
        isolateWatch.stop();

        // Visible from the main connection too? (Same database, not a copy.)
        final seenOnMain = _asInt(
          await _scalar(conn, 'SELECT COUNT(*) FROM isolate_probe'),
        );
        _add(
          'Background isolate (TransferableDatabase)',
          'isolate wrote $fromIsolate rows in ${isolateWatch.elapsedMilliseconds} ms\n'
              'main connection sees: $seenOnMain',
          ok: fromIsolate == 50000 && seenOnMain == 50000,
        );
      } on Object catch (e) {
        _add('Background isolate (TransferableDatabase)', 'FAILED: $e', ok: false);
      }

      // ---------------------------------------------------------------- 11
      // Durability. CHECKPOINT flushes the WAL into the main file.
      final ckWatch = Stopwatch()..start();
      await conn.execute('CHECKPOINT');
      ckWatch.stop();
      final dbFile = File(dbPath);
      final walFile = File('$dbPath.wal');
      _add(
        'CHECKPOINT + on-disk size',
        'checkpoint: ${ckWatch.elapsedMilliseconds} ms\n'
            'db:  ${_mb(dbFile)} \n'
            'wal: ${walFile.existsSync() ? _mb(walFile) : "absent (folded into db)"}',
        ok: true,
      );

      _add(
        'Cold start to checks complete',
        '${DateTime.now().difference(widget.processStart).inMilliseconds} ms '
            '(includes the 2M-row build — not the Phase 6 number)',
      );
    } on Object catch (e, st) {
      _fatal = '$e\n\n$st';
      stdout.writeln('[SPIKE] FATAL $e\n$st');
    } finally {
      stdout.writeln('[SPIKE] ==== checks complete ====');
      // Explicit dispose so the WAL is folded in. Android kills apps without
      // notice, so this is best-effort, not a guarantee — which is exactly why
      // the launch counter above is the real test.
      await conn?.dispose();
      await db?.dispose();
      if (mounted) setState(() => _running = false);
    }
  }

  String _mb(File f) {
    final bytes = f.lengthSync();
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final passed = _checks.where((c) => c.ok == true).length;
    final failed = _checks.where((c) => c.ok == false).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('DuckDB Phase 0 spike'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _running
                    ? 'running…'
                    : 'done — $passed passed, $failed failed',
                style: TextStyle(
                  color: failed > 0 ? Colors.red.shade200 : Colors.white70,
                ),
              ),
            ),
          ),
        ),
      ),
      body: _fatal != null
          ? SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                'FATAL\n\n$_fatal',
                style: const TextStyle(fontFamily: 'monospace', color: Colors.red),
              ),
            )
          : ListView.separated(
              itemCount: _checks.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final c = _checks[i];
                return ListTile(
                  leading: Icon(
                    switch (c.ok) {
                      true => Icons.check_circle,
                      false => Icons.cancel,
                      null => Icons.info_outline,
                    },
                    color: switch (c.ok) {
                      true => Colors.green,
                      false => Colors.red,
                      null => Colors.blueGrey,
                    },
                  ),
                  title: Text(
                    c.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: SelectableText(
                    c.detail,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                );
              },
            ),
    );
  }
}
