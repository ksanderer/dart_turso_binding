import 'dart:io';

import 'package:dart_turso_binding/dart_turso_binding.dart';
import 'package:test/test.dart';

void main() {
  test('queued writes never escape an engine-triggered rollback', () async {
    final directory = await Directory.systemTemp.createTemp('dtb-rollback-');
    final path = '${directory.path}/test.db';
    final db = await TursoDatabase.open(path);
    try {
      await db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY)');
      await expectLater(
        db.transaction((tx) async {
          await tx.execute('INSERT INTO items VALUES (1)');
          final failing = tx.execute(
            'INSERT OR ROLLBACK INTO items VALUES (1)',
          );
          final queued = tx.execute('INSERT INTO items VALUES (2)');
          await Future.wait([
            expectLater(failing, throwsA(isA<TursoException>())),
            expectLater(queued, throwsA(isA<TursoException>())),
          ]);
          await expectLater(
            tx.query('SELECT 1'),
            throwsA(isA<TursoException>()),
          );
        }),
        throwsA(isA<TursoException>()),
      );
    } finally {
      await db.close();
      try {
        final reopened = await TursoDatabase.open(path);
        try {
          expect((await reopened.query('SELECT id FROM items')).rows, isEmpty);
        } finally {
          await reopened.close();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    }
  });
}
