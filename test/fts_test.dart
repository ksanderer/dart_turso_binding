import 'package:dart_turso_binding/dart_turso_binding.dart';
import 'package:test/test.dart';

void main() {
  test(
    'configured trigrams lowercase Unicode and rank by descending score',
    () async {
      final database = await TursoDatabase.open(':memory:');
      addTearDown(database.close);
      await database.execute(
        'CREATE TABLE docs(id INTEGER PRIMARY KEY, title TEXT, content TEXT)',
      );
      await database.execute('''
      CREATE INDEX docs_fts ON docs USING fts (title, content)
      WITH (tokenizer='ngram', min_gram=3, max_gram=3, weights='title=3.0,content=1.0')
    ''');
      for (final row in [
        [1, 'Archive', 'world'],
        [2, 'World', ''],
        [3, 'Sword', ''],
        [4, 'Привет', ''],
      ]) {
        await database.execute('INSERT INTO docs VALUES (?, ?, ?)', row);
      }
      Future<List<List<Object?>>> search(String query) async =>
          (await database.query(
            '''
      SELECT id, fts_score(title, content, ?1) AS score FROM docs
      WHERE fts_match(title, content, ?1)
      ORDER BY score DESC LIMIT 10
    ''',
            [query],
          )).rows;
      final lower = await search('wor');
      expect(lower.map((row) => row.first), unorderedEquals([1, 2, 3]));
      expect(lower.last.first, 1);
      expect(await search('WOR'), lower);
      for (var index = 1; index < lower.length; index++) {
        expect(
          lower[index][1] as num,
          lessThanOrEqualTo(lower[index - 1][1] as num),
        );
      }
      expect(await search('wo'), isEmpty);
      expect((await search('ПРИ')).single.first, 4);
      await expectLater(
        database.transaction<void>((tx) async {
          await tx.execute("UPDATE docs SET title = 'Changed' WHERE id = 2");
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect(await search('wor'), unorderedEquals(lower));
      expect(await search('changed'), isEmpty);
    },
  );
}
