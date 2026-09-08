import 'dart:async';

import 'package:dart_turso_binding/dart_turso_binding.dart';
import 'package:test/test.dart';

void main() {
  late TursoDatabase db;
  setUp(() async {
    db = await TursoDatabase.open(':memory:');
    await db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY)');
  });
  tearDown(() => db.close());

  test('callback reads its writes and returns a value after commit', () async {
    final result = await db.transaction((tx) async {
      await tx.execute('INSERT INTO items VALUES (?)', [1]);
      return (await tx.query('SELECT id FROM items')).rows.single.single;
    });
    expect(result, 1);
    expect((await db.query('SELECT id FROM items')).rows, [
      [1],
    ]);
  });

  test('callback error rolls back and preserves the original error', () async {
    final error = StateError('validation failed');
    await expectLater(
      db.transaction((tx) async {
        await tx.execute('INSERT INTO items VALUES (1)');
        throw error;
      }),
      throwsA(same(error)),
    );
    expect((await db.query('SELECT count(*) FROM items')).rows, [
      [0],
    ]);
    await db.transaction((tx) => tx.execute('INSERT INTO items VALUES (2)'));
  });

  test('caught statement error still prevents partial commit', () async {
    await expectLater(
      db.transaction((tx) async {
        await tx.execute('INSERT INTO items VALUES (1)');
        await expectLater(
          tx.execute('INSERT INTO items VALUES (1)'),
          throwsA(isA<TursoException>()),
        );
      }),
      throwsA(isA<TursoException>()),
    );
    expect((await db.query('SELECT count(*) FROM items')).rows, [
      [0],
    ]);
  });

  test('unrelated operations wait across callback awaits', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final transaction = db.transaction((tx) async {
      await tx.execute('INSERT INTO items VALUES (1)');
      entered.complete();
      await release.future;
      expect((await tx.query('SELECT id FROM items')).rows, [
        [1],
      ]);
      await tx.execute('INSERT INTO items VALUES (2)');
    });
    await entered.future;
    var outsideCompleted = false;
    final outside = db.execute('INSERT INTO items VALUES (3)').then((_) {
      outsideCompleted = true;
    });
    final second = db.transaction(
      (tx) => tx.query('SELECT id FROM items ORDER BY id'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(outsideCompleted, isFalse);
    release.complete();
    await transaction;
    await outside;
    expect((await second).rows, [
      [1],
      [2],
      [3],
    ]);
  });

  test(
    'nested and direct database operations reject without deadlocking',
    () async {
      await db.transaction((tx) async {
        await expectLater(db.transaction((_) => 1), throwsStateError);
        await expectLater(db.query('SELECT 1'), throwsStateError);
        await expectLater(db.execute('SELECT 1'), throwsStateError);
        await expectLater(db.batch([]), throwsStateError);
        await expectLater(db.push(), throwsStateError);
        await expectLater(db.pull(), throwsStateError);
        await expectLater(db.checkpoint(), throwsStateError);
        await expectLater(db.stats(), throwsStateError);
        await expectLater(db.close(), throwsStateError);
        await tx.execute('INSERT INTO items VALUES (1)');
      });
      expect((await db.query('SELECT id FROM items')).rows, [
        [1],
      ]);
    },
  );

  test('handles expire after both commit and rollback', () async {
    late TursoTransaction committed;
    await db.transaction((tx) {
      committed = tx;
    });
    await expectLater(committed.query('SELECT 1'), throwsStateError);
    late TursoTransaction rolledBack;
    await expectLater(
      db.transaction((tx) {
        rolledBack = tx;
        throw StateError('rollback');
      }),
      throwsStateError,
    );
    await expectLater(
      rolledBack.execute('INSERT INTO items VALUES (1)'),
      throwsStateError,
    );
  });

  test(
    'close outside callback drains transaction and rejects new work',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final transaction = db.transaction((tx) async {
        entered.complete();
        await release.future;
        await tx.execute('INSERT INTO items VALUES (1)');
      });
      await entered.future;
      var closed = false;
      final closing = db.close().then((_) {
        closed = true;
      });
      await expectLater(db.query('SELECT 1'), throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(closed, isFalse);
      release.complete();
      await transaction;
      await closing;
      expect(closed, isTrue);
    },
  );

  test('submitted handle operations drain before commit', () async {
    late Future<ExecuteResult> write;
    await db.transaction((tx) {
      write = tx.execute('INSERT INTO items VALUES (1)');
    });
    await write;
    expect((await db.query('SELECT id FROM items')).rows, [
      [1],
    ]);
  });

  test('sync requests outside callback wait until transaction ends', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final transaction = db.transaction((tx) async {
      entered.complete();
      await release.future;
      await tx.execute('INSERT INTO items VALUES (1)');
    });
    await entered.future;
    var completed = 0;
    final requests = [db.push(), db.pull(), db.checkpoint(), db.stats()].map((
      request,
    ) async {
      await expectLater(request, throwsA(isA<TursoException>()));
      completed++;
    }).toList();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(completed, 0);
    release.complete();
    await transaction;
    await Future.wait(requests);
    expect(completed, 4);
  });

  test('invalid parameters abort the transaction even when caught', () async {
    await expectLater(
      db.transaction((tx) async {
        await tx.execute('INSERT INTO items VALUES (1)');
        await expectLater(
          tx.execute('INSERT INTO items VALUES (?)', [true]),
          throwsArgumentError,
        );
      }),
      throwsArgumentError,
    );
    expect((await db.query('SELECT count(*) FROM items')).rows, [
      [0],
    ]);
  });

  test(
    'begin failure never enters callback or rolls back an existing transaction',
    () async {
      await db.execute('BEGIN IMMEDIATE');
      await db.execute('INSERT INTO items VALUES (1)');
      var entered = false;
      await expectLater(
        db.transaction((_) {
          entered = true;
        }),
        throwsA(isA<TursoException>()),
      );
      expect(entered, isFalse);
      expect((await db.query('SELECT id FROM items')).rows, [
        [1],
      ]);
      await db.execute('ROLLBACK');
      expect((await db.query('SELECT count(*) FROM items')).rows, [
        [0],
      ]);
    },
  );

  test(
    'commit and rollback failure poison queued work but still allow close',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final transaction = db.transaction((tx) async {
        // Deliberate contract violation to exercise defensive cleanup: the caller
        // must never issue transaction-control SQL through a handle.
        await tx.execute('ROLLBACK');
        entered.complete();
        await release.future;
      });
      final failed = expectLater(
        transaction,
        throwsA(
          isA<TursoException>().having(
            (error) => error.message,
            'message',
            contains('rollback failed'),
          ),
        ),
      );
      await entered.future;
      final queued = expectLater(
        db.query('SELECT 1'),
        throwsA(isA<TursoException>()),
      );
      release.complete();
      await failed;
      await queued;
      await expectLater(
        db.transaction((_) => 1),
        throwsA(isA<TursoException>()),
      );
      await db.close();
      await expectLater(db.query('SELECT 1'), throwsStateError);
    },
  );
}
