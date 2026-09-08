import 'dart:convert';
import 'package:dart_turso_binding/dart_turso_binding.dart';

Future<void> main() async {
  final db = await TursoDatabase.open(':memory:');
  final results = <String, Object?>{};
  try {
    for (final sql in [
      'PRAGMA secure_delete=ON',
      'PRAGMA secure_delete',
      'PRAGMA journal_mode=DELETE',
      'PRAGMA journal_mode',
      'PRAGMA busy_timeout=5000',
      'PRAGMA busy_timeout',
      'PRAGMA application_id=1331057740',
      'PRAGMA application_id',
      "SELECT 'Hello' = 'hello' COLLATE NOCASE",
      'PRAGMA wal_checkpoint(TRUNCATE)',
    ]) {
      try {
        final result = await db.query(sql);
        results[sql] = {'columns': result.columns, 'rows': result.rows};
      } catch (error) {
        results[sql] = '$error';
      }
    }
    print(const JsonEncoder.withIndent('  ').convert(results));
  } finally {
    await db.close();
  }
}
