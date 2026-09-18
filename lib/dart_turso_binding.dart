/// Asynchronous access to the native Turso engine (not libSQL).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/native.dart' as native;

/// An error reported by the native binding or database engine.
final class TursoException implements Exception {
  const TursoException(this.message);
  final String message;
  @override
  String toString() => 'TursoException: $message';
}

/// One parameterized statement. Parameters are positional, using `?` or `?1`.
final class SqlStatement {
  SqlStatement(this.sql, [List<Object?> parameters = const []])
    : parameters = List.unmodifiable(parameters);
  final String sql;
  final List<Object?> parameters;

  Map<String, Object?> _encode() => {
    'sql': sql,
    'parameters': parameters.map(_encodeValue).toList(),
  };
}

/// Column names and ordered rows; duplicate column names are preserved.
final class QueryResult {
  QueryResult._(Map<String, dynamic> value)
    : columns = List<String>.unmodifiable(value['columns'] as List),
      rows = List.unmodifiable([
        for (final row in value['rows'] as List)
          List<Object?>.unmodifiable((row as List).map(_decodeValue)),
      ]);
  final List<String> columns;
  final List<List<Object?>> rows;
}

/// Metadata returned by a completed SQL statement.
final class ExecuteResult {
  ExecuteResult._(Map<String, dynamic> value)
    : rowsAffected = value['rowsAffected'] as int,
      lastInsertRowId = int.parse(value['lastInsertRowId'] as String);
  final int rowsAffected;
  final int lastInsertRowId;
}

/// One database and SQL connection, owned by a dedicated worker isolate.
///
/// Operations are serialized in submission order. Always await [close].
/// Queries buffer their entire result; use SQL LIMIT for large datasets.
final class TursoDatabase {
  TursoDatabase._();

  final _events = ReceivePort();
  final _ready = Completer<SendPort>();
  final _pending = <int, Completer<Object?>>{};
  late final StreamSubscription<dynamic> _subscription;
  SendPort? _commands;
  int _sequence = 0;
  bool _closing = false;
  Object? _failure;
  Future<void>? _closeFuture;
  final _operations = _OperationQueue();
  final _transactionZone = Object();
  Object? _transactionFailure;

  void _checkSubmission() {
    if (_closing) throw StateError('Database is closed');
    if (Zone.current[_transactionZone] == true) {
      throw StateError('Use the transaction handle inside a transaction');
    }
  }

  Future<T> _schedule<T>(Future<T> Function() action) => _operations.run(() {
    if (_transactionFailure case final failure?) throw failure;
    return action();
  });

  /// Open an in-memory or file-backed local database with FTS enabled.
  /// Opt into Turso's experimental WITHOUT ROWID support for this database.
  /// Pass the same option on every reopen; separate readers inherit it.
  static Future<TursoDatabase> open(
    String path, {
    bool experimentalWithoutRowid = false,
  }) => _open({
    'op': 'open',
    'path': path,
    'experimental_without_rowid': experimentalWithoutRowid,
  });

  /// Open a local-first sync database. No initial download unless requested.
  ///
  /// [bootstrap] requires a reachable server on first open. A static token is
  /// used for this session; close and reopen to rotate it. Do not embed shared
  /// administrative credentials in a distributed application.
  static Future<TursoDatabase> synced({
    required String path,
    required String remoteUrl,
    String? authToken,
    bool bootstrap = false,
  }) => _open({
    'op': 'open',
    'path': path,
    'remote_url': remoteUrl,
    'auth_token': authToken,
    'bootstrap': bootstrap,
  });

  static Future<TursoDatabase> _open(Map<String, Object?> options) async {
    final db = TursoDatabase._();
    db._subscription = db._events.listen(db._onEvent);
    try {
      await Isolate.spawn(
        _worker,
        db._events.sendPort,
        onError: db._events.sendPort,
        onExit: db._events.sendPort,
        errorsAreFatal: true,
      );
      db._commands = await db._ready.future;
      await db._send(options);
      return db;
    } catch (_) {
      await db.close();
      rethrow;
    }
  }

  void _onEvent(dynamic event) {
    if (event is SendPort) {
      _ready.complete(event);
    } else if (event is List && event.first is int) {
      final completer = _pending.remove(event[0]);
      final response = event[1] as Map;
      if (response.containsKey('error')) {
        completer?.completeError(TursoException(response['error'] as String));
      } else {
        completer?.complete(response['result']);
      }
    } else {
      final failure = TursoException(
        event == null ? 'Database worker exited' : 'Database worker failed',
      );
      _failure = failure;
      if (!_ready.isCompleted) _ready.completeError(failure);
      for (final request in _pending.values) {
        request.completeError(failure);
      }
      _pending.clear();
      _events.close();
    }
  }

  Future<Object?> _send(Map<String, Object?> message) {
    if (_failure != null) return Future.error(_failure!);
    final id = _sequence++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commands!.send([id, message]);
    return completer.future;
  }

  Future<Object?> _call(Map<String, Object?> message) async {
    _checkSubmission();
    return _schedule(() => _send(message));
  }

  /// Execute a single SQL statement. This is not a multi-statement script API.
  Future<ExecuteResult> execute(
    String sql, [
    List<Object?> parameters = const [],
  ]) async => ExecuteResult._(
    await _call({
          'op': 'execute',
          'statement': SqlStatement(sql, parameters)._encode(),
        })
        as Map<String, dynamic>,
  );

  /// Read a buffered result set. SQL values map to null/int/double/String/Uint8List.
  Future<QueryResult> query(
    String sql, [
    List<Object?> parameters = const [],
  ]) async => QueryResult._(
    await _call({
          'op': 'query',
          'statement': SqlStatement(sql, parameters)._encode(),
        })
        as Map<String, dynamic>,
  );

  /// Executes one parsed SELECT/VALUES statement on this local connection.
  /// DML, DDL, PRAGMA, transaction control and unsafe function calls are rejected.
  /// Limits: 64 KiB SQL, 10,000 rows, 4 MiB wire rows, 2 s native execution.
  /// Supports in-memory databases; synced databases are unsupported.
  Future<QueryResult> queryReadOnly(
    String sql, [
    List<Object?> parameters = const [],
  ]) async => QueryResult._(
    await _call({
          'op': 'query_read_only',
          'statement': SqlStatement(sql, parameters)._encode(),
        })
        as Map<String, dynamic>,
  );

  /// Run a read/validate/write callback under an exclusive BEGIN IMMEDIATE.
  ///
  /// Other database operations, including sync and close, wait for completion.
  /// Use only [TursoTransaction] for this database inside the callback; calling
  /// the database directly (including nested transactions or close) is rejected.
  /// The handle expires when the callback returns. Submitted handle operations
  /// are drained before commit; any failed operation rolls back the transaction,
  /// even if caught, except a failure isolated by a rolled-back savepoint.
  ///
  /// Transaction-control SQL must not be submitted through the handle.
  /// On callback/statement/commit failure, rollback is attempted. If rollback
  /// fails, subsequent work is rejected; [close] still releases the worker.
  Future<T> transaction<T>(
    FutureOr<T> Function(TursoTransaction tx) action,
  ) async {
    _checkSubmission();
    return _schedule(() async {
      await _transactionControl('BEGIN IMMEDIATE');
      final tx = TursoTransaction._(this);
      try {
        final result = await runZoned(
          () => action(tx),
          zoneValues: {_transactionZone: true},
        );
        await tx._finish();
        await _transactionControl('COMMIT');
        return result;
      } catch (error, stack) {
        tx._active = false;
        await tx._operations.drain;
        try {
          await _transactionControl('ROLLBACK');
        } catch (rollback) {
          final failure = TursoException(
            '$error; rollback failed: $rollback; close and reopen the database',
          );
          _transactionFailure = failure;
          throw failure;
        }
        Error.throwWithStackTrace(error, stack);
      }
    });
  }

  Future<Object?> _transactionControl(String sql) =>
      _send({'op': 'execute', 'statement': SqlStatement(sql)._encode()});

  /// Execute an atomic batch without interleaving other submitted operations.
  ///
  /// Statements must not contain transaction-control SQL (BEGIN/COMMIT/ROLLBACK).
  /// Use [transaction] when subsequent statements depend on query results.
  Future<List<int>> batch(List<SqlStatement> statements) async =>
      List<int>.unmodifiable(
        await _call({
              'op': 'batch',
              'statements': statements.map((s) => s._encode()).toList(),
            })
            as List,
      );

  /// Send local changes using the official sync protocol.
  Future<void> push() async {
    await _call({'op': 'push'});
  }

  /// Apply remote changes. Returns whether the SDK reported a change.
  Future<bool> pull() async => await _call({'op': 'pull'}) as bool;

  /// Compact WAL through the sync SDK, preserving pending sync state.
  Future<void> checkpoint() async {
    await _call({'op': 'checkpoint'});
  }

  /// Raw statistics keys from the pinned upstream SDK, not a stable schema.
  Future<Map<String, Object?>> stats() async =>
      Map<String, Object?>.unmodifiable(await _call({'op': 'stats'}) as Map);

  /// Drain submitted work and release native resources. Idempotent.
  ///
  /// Does not push pending writes; they remain on disk for a later session.
  Future<void> close() {
    if (Zone.current[_transactionZone] == true) {
      return Future.error(StateError('Cannot close inside a transaction'));
    }
    _closing = true;
    return _closeFuture ??= _operations.run(_close);
  }

  Future<void> _close() async {
    try {
      if (_commands != null && _failure == null) {
        await _send({'op': 'close'});
      }
    } finally {
      _events.close();
      await _subscription.cancel();
    }
  }
}

/// A callback-scoped connection. Never submit transaction-control SQL.
final class TursoTransaction {
  TursoTransaction._(this._database);

  final TursoDatabase _database;
  final _operations = _OperationQueue();
  bool _active = true;
  Object? _error;
  StackTrace? _stack;
  int _savepointSequence = 0;

  /// Isolate one operation. A handled failure rolls back only this savepoint.
  /// Use the supplied handle exclusively until this callback finishes.
  Future<T> savepoint<T>(FutureOr<T> Function(TursoTransaction tx) action) {
    if (!_active) {
      return Future.error(StateError('Transaction is no longer active'));
    }
    return _operations.run(() async {
      if (_error case final error?) Error.throwWithStackTrace(error, _stack!);
      final name = 'dart_operation_${++_savepointSequence}';
      final child = TursoTransaction._(_database);
      try {
        await _database._transactionControl('SAVEPOINT $name');
      } catch (error, stack) {
        _error = error;
        _stack = stack;
        rethrow;
      }
      try {
        final result = await runZoned(
          () => action(child),
          zoneValues: {_database._transactionZone: true},
        );
        await child._finish();
        await _database._transactionControl('RELEASE $name');
        return result;
      } catch (error, stack) {
        child._active = false;
        await child._operations.drain;
        try {
          await _database._transactionControl('ROLLBACK TO $name');
          await _database._transactionControl('RELEASE $name');
        } catch (rollback, rollbackStack) {
          _error = rollback;
          _stack = rollbackStack;
          Error.throwWithStackTrace(rollback, rollbackStack);
        }
        Error.throwWithStackTrace(error, stack);
      }
    });
  }

  Future<Object?> _call(String op, SqlStatement statement) async {
    if (!_active) throw StateError('Transaction is no longer active');
    return _operations.run(() async {
      // Some SQL errors can roll back the engine transaction themselves.
      // Never let later queued statements escape into autocommit in that case.
      if (_error case final error?) {
        Error.throwWithStackTrace(error, _stack!);
      }
      try {
        return await _database._send({
          'op': op,
          'statement': statement._encode(),
        });
      } catch (error, stack) {
        _error ??= error;
        _stack ??= stack;
        rethrow;
      }
    });
  }

  Future<ExecuteResult> execute(
    String sql, [
    List<Object?> parameters = const [],
  ]) async => ExecuteResult._(
    await _call('execute', SqlStatement(sql, parameters))
        as Map<String, dynamic>,
  );

  Future<QueryResult> query(
    String sql, [
    List<Object?> parameters = const [],
  ]) async => QueryResult._(
    await _call('query', SqlStatement(sql, parameters)) as Map<String, dynamic>,
  );

  /// Read-only SELECT/VALUES on this transaction's connection, seeing its writes.
  /// Has the same restrictions and bounds as [TursoDatabase.queryReadOnly].
  /// Use [savepoint] to isolate a caught query error.
  Future<QueryResult> queryReadOnly(
    String sql, [
    List<Object?> parameters = const [],
  ]) async => QueryResult._(
    await _call('query_read_only', SqlStatement(sql, parameters))
        as Map<String, dynamic>,
  );

  Future<void> _finish() async {
    _active = false;
    await _operations.drain;
    if (_error case final error?) {
      Error.throwWithStackTrace(error, _stack!);
    }
  }
}

final class _OperationQueue {
  Future<void> _tail = Future.value();
  Future<void> get drain => _tail;

  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

Map<String, Object?> _encodeValue(Object? value) => switch (value) {
  null => {'type': 'null'},
  int v => {'type': 'integer', 'value': v.toString()},
  double v when v.isFinite => {'type': 'real', 'value': v},
  String v => {'type': 'text', 'value': v},
  Uint8List v => {'type': 'blob', 'value': v.toList()},
  _ => throw ArgumentError(
    'SQL values must be null, int, finite double, String, or Uint8List',
  ),
};

Object? _decodeValue(dynamic cell) => switch (cell['type']) {
  'null' => null,
  'integer' => int.parse(cell['value'] as String),
  'real' => (cell['value'] as num).toDouble(),
  'text' => cell['value'] as String,
  'blob' => Uint8List.fromList((cell['value'] as List).cast<int>()),
  _ => throw const FormatException('Unknown native SQL value type'),
};

void _worker(SendPort parent) async {
  final session = native.create();
  if (session == nullptr) throw StateError('Cannot initialize native runtime');
  final commands = ReceivePort();
  parent.send(commands.sendPort);
  int? closeId;
  try {
    await for (final event in commands) {
      final message = event as List;
      final id = message[0] as int;
      final request = message[1] as Map<String, Object?>;
      if (request['op'] == 'close') {
        // Destroy before acknowledging close, so reopening the file is safe.
        closeId = id;
        break;
      }
      final input = jsonEncode(request).toNativeUtf8();
      try {
        final response = native.request(session, input.cast());
        try {
          parent.send([id, jsonDecode(response.cast<Utf8>().toDartString())]);
        } finally {
          native.free(response);
        }
      } finally {
        calloc.free(input);
      }
    }
  } finally {
    native.destroy(session);
    commands.close();
  }
  if (closeId != null) {
    parent.send([
      closeId,
      {'result': null},
    ]);
  }
}
