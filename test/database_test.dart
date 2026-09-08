import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_turso_binding/dart_turso_binding.dart';
import 'package:test/test.dart';

void main() {
  late TursoDatabase db;
  setUp(() async {
    db = await TursoDatabase.open(':memory:');
  });
  tearDown(() async {
    await db.close();
  });

  test(
    'round trips every supported value without losing int64 precision',
    () async {
      final values = <Object?>[
        null,
        -9223372036854775808,
        9223372036854775807,
        1.25,
        'Привет 世界\u0000tail',
        Uint8List.fromList([0, 127, 255]),
        Uint8List(0),
        '',
      ];
      final result = await db.query('SELECT ?, ?, ?, ?, ?, ?, ?, ?', values);
      expect(result.rows.single, values);
    },
  );

  test('preserves duplicate column names and empty result metadata', () async {
    final duplicate = await db.query('SELECT 1 AS x, 2 AS x');
    expect(duplicate.columns, ['x', 'x']);
    expect(duplicate.rows, [
      [1, 2],
    ]);
    final empty = await db.query('SELECT 1 AS x WHERE 0');
    expect(empty.columns, ['x']);
    expect(empty.rows, isEmpty);
  });

  test(
    'binds parameters rather than interpolating SQL and reports changes',
    () async {
      await db.execute('CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT)');
      const body = "'); DROP TABLE notes; --";
      final insert = await db.execute('INSERT INTO notes(body) VALUES (?)', [
        body,
      ]);
      expect(insert.rowsAffected, 1);
      expect(insert.lastInsertRowId, 1);
      expect((await db.query('SELECT body FROM notes')).rows, [
        [body],
      ]);
      expect(
        (await db.execute('UPDATE notes SET body=? WHERE id=?', [
          'ok',
          1,
        ])).rowsAffected,
        1,
      );
      expect(
        (await db.execute('DELETE FROM notes WHERE id=?', [1])).rowsAffected,
        1,
      );
    },
  );

  test('supports JSON functions', () async {
    expect(
      (await db.query(r"SELECT json_extract(?, '$.x')", ['{"x":42}'])).rows,
      [
        [42],
      ],
    );
  });

  test(
    'atomic batch commits or rolls back and connection stays usable',
    () async {
      await db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY)');
      expect(
        await db.batch([
          SqlStatement('INSERT INTO items VALUES (?)', [1]),
          SqlStatement('INSERT INTO items VALUES (?)', [2]),
        ]),
        [1, 1],
      );
      await expectLater(
        db.batch([
          SqlStatement('INSERT INTO items VALUES (?)', [3]),
          SqlStatement('INSERT INTO items VALUES (?)', [1]),
        ]),
        throwsA(isA<TursoException>()),
      );
      expect((await db.query('SELECT id FROM items ORDER BY id')).rows, [
        [1],
        [2],
      ]);
      await db.execute('INSERT INTO items VALUES (4)');
    },
  );

  test('concurrent submissions do not interleave with a batch', () async {
    await db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY)');
    final batch = db.batch([
      for (var i = 0; i < 100; i++)
        SqlStatement('INSERT INTO items VALUES (?)', [i]),
    ]);
    final count = db.query('SELECT count(*) FROM items');
    await batch;
    expect((await count).rows, [
      [100],
    ]);
  });

  test(
    'rejects unsupported values and SQL errors without poisoning worker',
    () async {
      for (final value in [true, double.infinity, double.nan, DateTime(2026)]) {
        await expectLater(db.query('SELECT ?', [value]), throwsArgumentError);
      }
      await expectLater(
        db.query('not valid sql'),
        throwsA(isA<TursoException>()),
      );
      expect((await db.query('SELECT 42')).rows, [
        [42],
      ]);
    },
  );

  test('rejects sync operations on a local-only database', () async {
    for (final op in [db.push, db.pull, db.checkpoint, db.stats]) {
      await expectLater(op(), throwsA(isA<TursoException>()));
    }
  });

  test('FTS tracks committed inserts updates and deletes', () async {
    await db.execute(
      'CREATE TABLE notes(id INTEGER PRIMARY KEY, title TEXT, body TEXT)',
    );
    await db.execute('CREATE INDEX notes_fts ON notes USING fts(title, body)');
    await db.execute('INSERT INTO notes VALUES (1, ?, ?)', [
      'Привет',
      'database search',
    ]);
    expect(
      (await db.query("SELECT id FROM notes WHERE fts_match(title, body, ?)", [
        'database AND search',
      ])).rows,
      [
        [1],
      ],
    );
    await db.execute('UPDATE notes SET body=? WHERE id=1', ['changed']);
    expect(
      (await db.query("SELECT id FROM notes WHERE fts_match(title, body, ?)", [
        'database',
      ])).rows,
      isEmpty,
    );
    expect(
      (await db.query("SELECT id FROM notes WHERE fts_match(title, body, ?)", [
        'changed',
      ])).rows,
      [
        [1],
      ],
    );
    await db.execute('DELETE FROM notes WHERE id=1');
    expect(
      (await db.query("SELECT id FROM notes WHERE fts_match(title, body, ?)", [
        'changed',
      ])).rows,
      isEmpty,
    );
  });

  test('SQL work does not block timers on the caller isolate', () async {
    await db.execute('CREATE TABLE numbers(x INTEGER)');
    await db.batch([
      for (var i = 0; i < 100; i++)
        SqlStatement('INSERT INTO numbers VALUES (?)', [i]),
    ]);
    var ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      ticks++;
    });
    try {
      await db.query(
        'SELECT sum(a.x + b.x + c.x) FROM numbers a CROSS JOIN numbers b CROSS JOIN numbers c',
      );
      expect(ticks, greaterThan(0));
    } finally {
      timer.cancel();
    }
  });

  test(
    'close drains outstanding work, is idempotent, and rejects new work',
    () async {
      final query = db.query('SELECT 42');
      final closed = db.close();
      expect((await query).rows, [
        [42],
      ]);
      await closed;
      await db.close();
      await expectLater(db.query('SELECT 1'), throwsStateError);
    },
  );

  test('file survives explicit close and reopen', () async {
    final directory = await Directory.systemTemp.createTemp('dtb-');
    try {
      final path = '${directory.path}/test.db';
      final first = await TursoDatabase.open(path);
      try {
        await first.execute('CREATE TABLE data(value TEXT)');
        await first.execute('INSERT INTO data VALUES (?)', ['persistent']);
      } finally {
        await first.close();
      }
      final second = await TursoDatabase.open(path);
      try {
        expect((await second.query('SELECT value FROM data')).rows, [
          ['persistent'],
        ]);
      } finally {
        await second.close();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('failed open releases the worker', () async {
    final directory = await Directory.systemTemp.createTemp('dtb-failure-');
    try {
      await expectLater(
        TursoDatabase.open('${directory.path}/missing/db'),
        throwsA(isA<TursoException>()),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
