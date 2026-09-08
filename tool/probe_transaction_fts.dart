import 'dart:convert';

import 'package:dart_turso_binding/dart_turso_binding.dart';

// Characterizes the pinned experimental FTS implementation on disposable data.
Future<void> main() async {
  final db = await TursoDatabase.open(':memory:');
  try {
    await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY, body TEXT)');
    await db.execute('CREATE INDEX docs_fts ON docs USING fts (body)');
    final observations = <String, Object?>{};
    await db.transaction((tx) async {
      await tx.execute('INSERT INTO docs VALUES (1, ?)', ['hello world']);
      observations['sqlInsideInsert'] = (await tx.query(
        'SELECT id FROM docs',
      )).rows;
      observations['ftsInsideInsert'] = (await tx.query(
        "SELECT id FROM docs WHERE fts_match(body, 'hello')",
      )).rows;
    });
    observations['ftsAfterCommit'] = (await db.query(
      "SELECT id FROM docs WHERE fts_match(body, 'hello')",
    )).rows;
    try {
      await db.transaction((tx) async {
        await tx.execute('UPDATE docs SET body = ? WHERE id = 1', [
          'goodbye world',
        ]);
        observations['oldTermInsideUpdate'] = (await tx.query(
          "SELECT id FROM docs WHERE fts_match(body, 'hello')",
        )).rows;
        observations['newTermInsideUpdate'] = (await tx.query(
          "SELECT id FROM docs WHERE fts_match(body, 'goodbye')",
        )).rows;
        throw const _RollbackProbe();
      });
    } on _RollbackProbe {
      observations['oldTermAfterRollback'] = (await db.query(
        "SELECT id FROM docs WHERE fts_match(body, 'hello')",
      )).rows;
      observations['newTermAfterRollback'] = (await db.query(
        "SELECT id FROM docs WHERE fts_match(body, 'goodbye')",
      )).rows;
    }
    print(const JsonEncoder.withIndent('  ').convert(observations));
  } finally {
    await db.close();
  }
}

final class _RollbackProbe implements Exception {
  const _RollbackProbe();
}
