import 'dart:io';

import 'package:dart_turso_binding/dart_turso_binding.dart';
import 'package:test/test.dart';

void main() {
  test('WITHOUT ROWID remains opt-in', () async {
    final db = await TursoDatabase.open(':memory:');
    try {
      await expectLater(
        db.execute('CREATE TABLE sample (id TEXT PRIMARY KEY) WITHOUT ROWID'),
        throwsA(isA<TursoException>()),
      );
    } finally {
      await db.close();
    }
  });

  test(
    'WITHOUT ROWID opt-in survives reopen and is inherited by readers',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'turso-without-rowid-',
      );
      final path = '${directory.path}/test.db';
      var db = await TursoDatabase.open(path, experimentalWithoutRowid: true);
      try {
        await db.execute(
          'CREATE TABLE sample (id TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID',
        );
        await db.transaction((tx) async {
          await tx.execute('INSERT INTO sample VALUES (?, ?)', [
            'one',
            'saved',
          ]);
        });
        await expectLater(
          db.transaction((tx) async {
            await tx.execute('INSERT INTO sample VALUES (?, ?)', [
              'two',
              'discard',
            ]);
            throw StateError('rollback');
          }),
          throwsStateError,
        );
        await db.close();
        db = await TursoDatabase.open(path, experimentalWithoutRowid: true);
        expect((await db.query('SELECT id, value FROM sample')).rows, [
          ['one', 'saved'],
        ]);
        expect((await db.queryReadOnly('SELECT id, value FROM sample')).rows, [
          ['one', 'saved'],
        ]);
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
