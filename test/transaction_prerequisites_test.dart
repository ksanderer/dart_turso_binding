import 'package:dart_turso_binding/dart_turso_binding.dart';
import 'package:test/test.dart';

// These sequential engine probes are not an interactive transaction API.
// Production callbacks need an exclusive lease across the entire callback.
void main() {
  late TursoDatabase db;
  setUp(() async {
    db = await TursoDatabase.open(':memory:');
  });
  tearDown(() => db.close());

  test(
    'BEGIN IMMEDIATE supports read validate write and explicit rollback',
    () async {
      await db.execute(
        'CREATE TABLE counters(id TEXT PRIMARY KEY, value INTEGER)',
      );
      await db.execute("INSERT INTO counters VALUES ('note', 0)");
      await db.execute('BEGIN IMMEDIATE');
      final value =
          (await db.query('SELECT value FROM counters')).rows.single.single
              as int;
      await db.execute('UPDATE counters SET value = ?', [value + 1]);
      expect((await db.query('SELECT value FROM counters')).rows, [
        [1],
      ]);
      await db.execute('ROLLBACK');
      expect((await db.query('SELECT value FROM counters')).rows, [
        [0],
      ]);
      await db.execute('BEGIN IMMEDIATE');
      await db.execute('UPDATE counters SET value = 2');
      await db.execute('COMMIT');
      expect((await db.query('SELECT value FROM counters')).rows, [
        [2],
      ]);
    },
  );

  test('statement error allows rollback of all preceding writes', () async {
    await db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY)');
    await db.execute('BEGIN IMMEDIATE');
    await db.execute('INSERT INTO items VALUES (1)');
    await expectLater(
      db.execute('INSERT INTO items VALUES (1)'),
      throwsA(isA<TursoException>()),
    );
    await db.execute('ROLLBACK');
    expect((await db.query('SELECT count(*) FROM items')).rows, [
      [0],
    ]);
    await db.execute('BEGIN IMMEDIATE');
    await db.execute('INSERT INTO items VALUES (2)');
    await db.execute('COMMIT');
    expect((await db.query('SELECT id FROM items')).rows, [
      [2],
    ]);
  });

  test('Vault JSON checks expression indexes upsert and returning', () async {
    await db.execute(
      "CREATE TABLE entities(id TEXT PRIMARY KEY, doc TEXT NOT NULL CHECK(json_valid(doc)))",
    );
    await db.execute(
      "CREATE INDEX entities_parent ON entities(json_extract(doc, '\$.parent'))",
    );
    await db.execute(
      'INSERT INTO entities VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET doc=excluded.doc',
      ['note-1', '{"parent":"root"}'],
    );
    await db.execute(
      'INSERT INTO entities VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET doc=excluded.doc',
      ['note-1', '{"parent":"other"}'],
    );
    expect(
      (await db.query(
        "SELECT id FROM entities WHERE json_extract(doc, '\$.parent') = ?",
        ['other'],
      )).rows,
      [
        ['note-1'],
      ],
    );
    expect(
      (await db.query('UPDATE entities SET doc = ? WHERE id = ? RETURNING id', [
        '{}',
        'note-1',
      ])).rows,
      [
        ['note-1'],
      ],
    );
    await expectLater(
      db.execute('INSERT INTO entities VALUES (?, ?)', [
        'note-2',
        'invalid json',
      ]),
      throwsA(isA<TursoException>()),
    );
  });

  test('foreign key enforcement rejects orphan writes', () async {
    await db.execute('PRAGMA foreign_keys = ON');
    await db.execute('CREATE TABLE parents(id TEXT PRIMARY KEY)');
    await db.execute(
      'CREATE TABLE children(parent TEXT REFERENCES parents(id))',
    );
    await expectLater(
      db.execute("INSERT INTO children VALUES ('missing')"),
      throwsA(isA<TursoException>()),
    );
    await db.execute("INSERT INTO parents VALUES ('present')");
    await db.execute("INSERT INTO children VALUES ('present')");
    await expectLater(
      db.execute("DELETE FROM parents WHERE id = 'present'"),
      throwsA(isA<TursoException>()),
    );
  });
}
