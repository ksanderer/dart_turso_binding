import 'package:dart_turso_binding/dart_turso_binding.dart';
import 'package:test/test.dart';

void main() {
  late TursoDatabase db;
  setUp(() async {
    db = await TursoDatabase.open(':memory:');
    await db.execute('CREATE TABLE items(id TEXT PRIMARY KEY)');
    await db.execute('CREATE TABLE audit(value TEXT)');
    await db.execute(
      "CREATE TRIGGER changed AFTER UPDATE ON items BEGIN INSERT INTO audit VALUES ('changed'); END",
    );
  });
  tearDown(() => db.close());

  test(
    'read-only SELECT sees transaction writes and all changes roll back',
    () async {
      await expectLater(
        db.transaction((tx) async {
          await tx.execute("INSERT INTO items VALUES ('one')");
          expect(
            (await tx.queryReadOnly(
              'WITH selected AS (SELECT id FROM items) SELECT id FROM selected',
            )).rows,
            [
              ['one'],
            ],
          );
          throw StateError('abort');
        }),
        throwsStateError,
      );
      expect((await db.queryReadOnly('SELECT * FROM items')).rows, isEmpty);
    },
  );

  test(
    'caught rejected SQL cannot mutate, escape or poison the transaction',
    () async {
      await db.transaction((tx) async {
        await tx.execute("INSERT INTO items VALUES ('one')");
        for (final sql in [
          'DELETE FROM items RETURNING id',
          'WITH c AS (SELECT 1) DELETE FROM items',
          'CREATE TABLE escaped(id)',
          'CREATE VIEW escaped AS SELECT id FROM items',
          'DROP TABLE items',
          'DROP TRIGGER changed',
          'PRAGMA user_version=42',
          'PRAGMA application_id=42',
          'PRAGMA query_only=0',
          'COMMIT',
          'ROLLBACK',
          'SAVEPOINT escaped',
          "ATTACH ':memory:' AS escaped",
          "SELECT id FROM items; DELETE FROM items",
          "SELECT load_extension('missing')",
          '''SELECT "LOAD_EXTENSION"('missing')''',
          "SELECT * FROM pragma_journal_mode('delete')",
          "SELECT * FROM json_each('[1]'), pragma_table_info('items')",
          'SELECT absent FROM items',
        ]) {
          await expectLater(
            tx.savepoint((operation) => operation.queryReadOnly(sql)),
            throwsA(isA<TursoException>()),
            reason: sql,
          );
          expect((await tx.queryReadOnly('SELECT id FROM items')).rows, [
            ['one'],
          ], reason: sql);
        }
        await expectLater(
          tx.savepoint(
            (operation) => operation.queryReadOnly(
              'WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n) SELECT x FROM n',
            ),
          ),
          throwsA(
            isA<TursoException>().having(
              (e) => e.message,
              'row budget',
              contains('10000'),
            ),
          ),
        );
        expect(
          (await tx.queryReadOnly(
            "SELECT name FROM sqlite_schema WHERE type='trigger'",
          )).rows,
          [
            ['changed'],
          ],
        );
        expect(
          (await tx.queryReadOnly("SELECT value FROM json_each('[1,2]')")).rows,
          [
            [1],
            [2],
          ],
        );
        await tx.execute("INSERT INTO items VALUES ('two')");
      });
      expect(
        (await db.queryReadOnly('SELECT id FROM items ORDER BY id')).rows,
        [
          ['one'],
          ['two'],
        ],
      );
    },
  );

  test(
    'row, byte, source and native CPU bounds leave the connection usable',
    () async {
      for (final sql in [
        'WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10001) SELECT x FROM n',
        'SELECT zeroblob(3000000)',
        "SELECT '${'x' * 65536}'",
        'WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n) SELECT sum(x) FROM n',
      ]) {
        await expectLater(
          db.queryReadOnly(sql),
          throwsA(isA<TursoException>()),
        );
        expect((await db.queryReadOnly('VALUES(1)')).rows, [
          [1],
        ]);
      }
      await db.execute("INSERT INTO items VALUES ('after')");
    },
    timeout: Timeout(Duration(seconds: 15)),
  );
}
