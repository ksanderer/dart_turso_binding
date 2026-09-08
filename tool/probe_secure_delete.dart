import 'dart:convert';
import 'dart:io';
import 'package:dart_turso_binding/dart_turso_binding.dart';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp(
    'turso-delete-probe-',
  );
  final path = '${directory.path}/probe.db';
  final marker =
      'synthetic-deletion-marker-${List.filled(64, '0123456789abcdef').join()}';
  final db = await TursoDatabase.open(path);
  final results = <String, Object?>{};
  Future<Map<String, bool>> retained() async => {
    for (final suffix in ['', '-wal'])
      suffix.isEmpty ? 'database' : 'wal':
          await File('$path$suffix').exists() &&
          latin1
              .decode(await File('$path$suffix').readAsBytes())
              .contains(marker),
  };
  try {
    await db.execute('PRAGMA secure_delete=ON');
    await db.query('PRAGMA journal_mode=DELETE');
    await db.execute(
      'CREATE TABLE records(id INTEGER PRIMARY KEY, payload TEXT)',
    );
    await db.execute('INSERT INTO records VALUES (1, ?)', [marker]);
    await db.query('PRAGMA wal_checkpoint(TRUNCATE)');
    results['afterInsertCheckpoint'] = await retained();
    await db.execute('DELETE FROM records');
    results['afterDelete'] = await retained();
    await db.query('PRAGMA wal_checkpoint(TRUNCATE)');
    results['afterDeleteCheckpoint'] = await retained();
    try {
      await db.execute('VACUUM');
      await db.query('PRAGMA wal_checkpoint(TRUNCATE)');
      results['afterVacuum'] = await retained();
    } catch (error) {
      results['vacuumError'] = '$error';
    }
    await db.close();
    results['afterClose'] = await retained();
    print(const JsonEncoder.withIndent('  ').convert(results));
  } finally {
    await db.close();
    await directory.delete(recursive: true);
  }
}
