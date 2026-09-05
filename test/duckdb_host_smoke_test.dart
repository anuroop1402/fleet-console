import 'package:dart_duckdb/dart_duckdb.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/duckdb_test_env.dart';

void main() {
  setUpAll(configureDuckDbForTests);

  test('DuckDB loads and answers a query on the host', () async {
    final db = await duckdb.open(':memory:');
    final conn = await duckdb.connect(db);
    final result = await conn.query('SELECT 40 + 2');
    expect(result.fetchAll().first.first, 42);
    await result.dispose();
    await conn.dispose();
    await db.dispose();
  });
}
