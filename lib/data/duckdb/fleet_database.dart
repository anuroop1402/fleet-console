/// Opens the on-device DuckDB database and brings the schema up to date.
library;

import 'package:dart_duckdb/dart_duckdb.dart';

import 'schema.dart';

/// Owns the DuckDB handle and the write connection.
///
/// One connection is deliberate. Each `Connection` in `dart_duckdb` spawns its
/// own Dart isolate, so connections are expensive and a connection-per-query
/// would be pathological. Background work (backfill, replay) gets its own
/// connection inside its own isolate via [transferable].
final class FleetDatabase {
  FleetDatabase._(this._database, this.connection, this.path);

  final Database _database;
  final Connection connection;

  /// Where the database lives on disk. `:memory:` in tests that do not care
  /// about durability.
  final String path;

  /// A handle that can cross an isolate boundary.
  ///
  /// It is the underlying pointer address wrapped in an int, so it is valid
  /// only within this process and only while this [FleetDatabase] is alive.
  /// Disposing this object invalidates it.
  TransferableDatabase get transferable => _database.transferable;

  static Future<FleetDatabase> open(String path) async {
    final database = await duckdb.open(path);
    final connection = await duckdb.connect(database);
    final db = FleetDatabase._(database, connection, path);
    await db._migrate();
    return db;
  }

  /// Applies any migrations this database has not seen.
  ///
  /// The version table is created outside the loop because we have to read it
  /// to know what to apply.
  Future<void> _migrate() async {
    await connection.execute('''
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version    INTEGER   NOT NULL,
        applied_at TIMESTAMP NOT NULL,
        PRIMARY KEY (version)
      )
    ''');

    final applied = await _appliedVersions();

    for (var index = 0; index < migrations.length; index++) {
      final version = index + 1;
      if (applied.contains(version)) continue;

      // Each migration is atomic: either the schema change and the version row
      // both land, or neither does. A half-applied migration on a device that
      // was killed mid-write is not a state worth supporting.
      await connection.execute('BEGIN TRANSACTION');
      try {
        await connection.execute(migrations[index]);
        final stmt = await connection.prepare(
          'INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)',
        );
        stmt.bind(version, 1);
        stmt.bind(DateTime.now().toUtc(), 2);
        await (await stmt.execute()).dispose();
        await stmt.dispose();
        await connection.execute('COMMIT');
      } on Object {
        await connection.execute('ROLLBACK');
        rethrow;
      }
    }
  }

  Future<Set<int>> _appliedVersions() async {
    final result = await connection.query(
      'SELECT version FROM schema_migrations',
    );
    try {
      return {
        for (final row in result.fetchAll()) (row.first! as num).toInt(),
      };
    } finally {
      await result.dispose();
    }
  }

  /// Folds the write-ahead log into the main database file.
  ///
  /// Android kills apps without warning, so this is called at natural
  /// checkpoints rather than relying on [dispose] running.
  Future<void> checkpoint() => connection.execute('CHECKPOINT');

  Future<void> dispose() async {
    await connection.dispose();
    await _database.dispose();
  }
}
