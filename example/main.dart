import 'package:dart_turso_binding/dart_turso_binding.dart';

Future<void> main() async {
  final db = await TursoDatabase.open(':memory:');
  try {
    await db.execute('CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT)');
    await db.batch([
      SqlStatement('INSERT INTO notes(body) VALUES (?)', ['Hello, Turso']),
      SqlStatement('INSERT INTO notes(body) VALUES (?)', ['Local-first Dart']),
    ]);
    final result = await db.query('SELECT id, body FROM notes ORDER BY id');
    print(result.columns);
    for (final row in result.rows) {
      print(row);
    }
  } finally {
    await db.close();
  }
}
