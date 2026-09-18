import 'dart:convert';

import 'package:dart_turso_binding/dart_turso_binding.dart';

/// Diagnostic only: all operations use an isolated in-memory database.
Future<void> main() async {
  final db = await TursoDatabase.open(':memory:');
  try {
    await db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO items VALUES (1)');
    Future<void> probe(String label, Future<Object?> Function() action) async {
      try {
        print('$label: ${jsonEncode(await action())}');
      } catch (error) {
        print('$label: rejected: $error');
      }
    }

    await probe(
      'multiple statements',
      () async =>
          (await db.query('SELECT id FROM items; DELETE FROM items')).rows,
    );
    await probe(
      'count after multiple statements',
      () async => (await db.query('SELECT count(*) FROM items')).rows,
    );
    await probe(
      'query() with write RETURNING',
      () async => (await db.query('UPDATE items SET id=2 RETURNING id')).rows,
    );
    await db.execute('PRAGMA query_only=1');
    await probe(
      'query_only value',
      () async => (await db.query('PRAGMA query_only')).rows,
    );
    await probe(
      'write with query_only enabled',
      () async => (await db.query('DELETE FROM items RETURNING id')).rows,
    );
    await probe(
      'query_only=0 with trailing statement',
      () async => (await db.query('PRAGMA query_only=0; SELECT 42')).rows,
    );
    await probe(
      'query_only after trailing statement',
      () async => (await db.query('PRAGMA query_only')).rows,
    );
    await probe(
      'write after disabling query_only',
      () async => (await db.query('UPDATE items SET id=3 RETURNING id')).rows,
    );
    await probe(
      'semicolon in literal',
      () async =>
          (await db.query("SELECT ';' AS value -- trailing comment")).rows,
    );
    await probe(
      'final records',
      () async => (await db.query('SELECT id FROM items')).rows,
    );
  } finally {
    await db.close();
  }
}
