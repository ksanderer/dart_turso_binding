import 'dart:io';
import 'dart:typed_data';

import 'package:dart_turso_binding/dart_turso_binding.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late TursoDatabase db;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('turso-read-query-');
    db = await TursoDatabase.open('${directory.path}/test.db');
    await db.execute('CREATE TABLE items(id TEXT PRIMARY KEY)');
    await db.execute('INSERT INTO items VALUES (?)', ['one']);
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'reader preserves column metadata, parameters, Unicode and blobs',
    () async {
      final result = await db.queryReadOnly(
        'SELECT ? AS value, ? AS value; -- allowed tail',
        [
          'Привет; -- literal',
          Uint8List.fromList([0, 255, 42]),
        ],
      );
      expect(result.columns, ['value', 'value']);
      expect(result.rows.single[0], 'Привет; -- literal');
      expect(result.rows.single[1], [0, 255, 42]);
    },
  );

  test(
    'multiple statements reject before execution and DML cannot disable the writer',
    () async {
      await expectLater(
        db.queryReadOnly('DELETE FROM items; SELECT id FROM items'),
        throwsA(isA<TursoException>()),
      );
      await expectLater(
        db.queryReadOnly('PRAGMA query_only=0'),
        throwsA(isA<TursoException>()),
      );
      await expectLater(
        db.queryReadOnly('DELETE FROM items RETURNING id'),
        throwsA(isA<TursoException>()),
      );
      await db.execute('INSERT INTO items VALUES (?)', ['two']);
      expect(
        (await db.queryReadOnly('SELECT id FROM items ORDER BY id')).rows,
        [
          ['one'],
          ['two'],
        ],
      );
    },
  );

  test('reader failures do not poison later queries', () async {
    await expectLater(
      db.queryReadOnly('SELECT absent FROM items'),
      throwsA(isA<TursoException>()),
    );
    expect(
      (await db.queryReadOnly(
        'WITH selected AS (SELECT id FROM items) SELECT id FROM selected',
      )).rows,
      [
        ['one'],
      ],
    );
  });

  test('in-memory reader uses the owning connection', () async {
    final memory = await TursoDatabase.open(':memory:');
    try {
      expect((await memory.queryReadOnly('SELECT 1')).rows, [
        [1],
      ]);
      expect((await memory.query('SELECT 1')).rows, [
        [1],
      ]);
    } finally {
      await memory.close();
    }
  });
}
