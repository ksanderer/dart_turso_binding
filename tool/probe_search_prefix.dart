import 'dart:convert';

import 'package:dart_turso_binding/dart_turso_binding.dart';

// Disposable fixtures for comparing documented FTS capabilities with the pinned
// engine. This is a diagnostic, not an application search implementation.
Future<void> main() async {
  final observations = <String, Object?>{};
  for (final tokenizer in ['default', 'ngram']) {
    final db = await TursoDatabase.open(':memory:');
    try {
      await db.execute(
        'CREATE TABLE docs(id INTEGER PRIMARY KEY, title TEXT, content TEXT)',
      );
      await db.execute(
        "CREATE INDEX docs_fts ON docs USING fts (title, content) WITH (tokenizer='$tokenizer', weights='title=3.0,content=1.0')",
      );
      final documents = <List<Object?>>[
        [1, 'world', 'world world world'],
        [2, 'world', 'world'],
        [3, 'work', 'working'],
        [4, 'sword', ''],
        [5, 'World', ''],
        [6, 'привет', 'мир'],
        [7, 'foo world', ''],
      ];
      for (final row in documents) {
        await db.execute('INSERT INTO docs VALUES (?, ?, ?)', row);
      }
      final results = <String, Object?>{};
      for (final query in [
        'world',
        'wor',
        'w',
        'Wor',
        'ми',
        'wor*',
        '"wor"*',
        '"foo wor"*',
        'title:world^5 OR content:world',
        '(title:[wor TO wos} OR content:[wor TO wos})',
        '(title:[wor TO wos})^3 OR content:[wor TO wos}',
      ]) {
        try {
          const sql =
              'SELECT id, fts_score(title, content, ?1) AS score FROM docs WHERE fts_match(title, content, ?1) ORDER BY score DESC, id';
          results[query] = {
            'rows': (await db.query(sql, [query])).rows,
            'plan': (await db.query('EXPLAIN QUERY PLAN $sql', [query])).rows,
          };
        } on Object catch (error) {
          results[query] = {'error': '$error'};
        }
      }
      final ordering = <String, Object?>{};
      for (final order in [
        'score DESC LIMIT 10',
        'score DESC, id LIMIT 10',
        '(score + 0) DESC, id LIMIT 10',
      ]) {
        final sql =
            'SELECT id, fts_score(title, content, ?1) AS score FROM docs WHERE fts_match(title, content, ?1) ORDER BY $order';
        try {
          ordering[order] = {
            'rows': (await db.query(sql, ['wor'])).rows,
            'plan': (await db.query('EXPLAIN QUERY PLAN $sql', ['wor'])).rows,
          };
        } on Object catch (error) {
          ordering[order] = {'error': '$error'};
        }
      }
      results['orderingProbe'] = ordering;
      observations[tokenizer] = {'documents': documents, 'results': results};
    } finally {
      await db.close();
    }
  }
  print(const JsonEncoder.withIndent('  ').convert(observations));
}
