import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_turso_binding/dart_turso_binding.dart';
import 'package:test/test.dart';

void main() {
  final server =
      Platform.environment['DTB_SYNC_SERVER'] ??
      '${Directory.current.path}/.dart_tool/sync-server/tursodb${Platform.isWindows ? '.exe' : ''}';
  final available = File(server).existsSync();
  test('required sync server is installed', () {
    if (Platform.environment['DTB_REQUIRE_SYNC_TESTS'] == '1') {
      expect(available, isTrue);
    }
  });

  test(
    'offline reopen, push/pull, conflicts and sync checkpoint',
    () async {
      final directory = await Directory.systemTemp.createTemp('dtb-sync-');
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final remote = 'http://127.0.0.1:$port';
      Process? process;
      final clients = <TursoDatabase>[];
      final output = StringBuffer();
      Future<TursoDatabase> open(String name) async {
        final db = await TursoDatabase.synced(
          path: '${directory.path}/$name.db',
          remoteUrl: remote,
        );
        clients.add(db);
        return db;
      }

      try {
        // No server is running: first launch and durable local writes must work.
        var a = await open('a');
        await a.execute('CREATE TABLE notes(id TEXT PRIMARY KEY, body TEXT)');
        await a.execute('INSERT INTO notes VALUES (?, ?)', ['n1', 'offline']);
        await expectLater(a.push(), throwsA(isA<TursoException>()));
        await a.close();
        a = await open('a');
        expect((await a.query('SELECT body FROM notes')).rows, [
          ['offline'],
        ]);

        process = await Process.start(server, [
          '${directory.path}/remote.db',
          '--sync-server',
          '127.0.0.1:$port',
          '--experimental-index-method',
        ]);
        process.stdout.transform(utf8.decoder).listen(output.write);
        process.stderr.transform(utf8.decoder).listen(output.write);
        var ready = false;
        for (var i = 0; i < 100; i++) {
          try {
            final socket = await Socket.connect(
              '127.0.0.1',
              port,
              timeout: const Duration(milliseconds: 100),
            );
            socket.destroy();
            ready = true;
            break;
          } on SocketException {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        expect(ready, isTrue, reason: output.toString());
        await a.push();
        final b = await open('b');
        expect(await b.pull(), isTrue);
        expect((await b.query('SELECT body FROM notes')).rows, [
          ['offline'],
        ]);
        await a.pull();
        await a.execute('UPDATE notes SET body=? WHERE id=?', ['A', 'n1']);
        await b.execute('UPDATE notes SET body=? WHERE id=?', ['B', 'n1']);
        await a.push();
        await b.push();
        await a.pull();
        await b.pull();
        expect((await a.query('SELECT body FROM notes')).rows, [
          ['B'],
        ]);
        expect((await b.query('SELECT body FROM notes')).rows, [
          ['B'],
        ]);
        await a.execute('INSERT INTO notes VALUES (?, ?)', ['n2', 'pending']);
        await a.checkpoint();
        expect(await a.stats(), isNotEmpty);
        await a.close();
        a = await open('a');
        await a.push();
        await b.pull();
        expect(
          (await b.query('SELECT body FROM notes WHERE id=?', ['n2'])).rows,
          [
            ['pending'],
          ],
        );

        await a.execute(
          'CREATE TABLE search_docs(id INTEGER PRIMARY KEY, body TEXT)',
        );
        await a.execute(
          'CREATE INDEX search_fts ON search_docs USING fts(body)',
        );
        await a.execute('INSERT INTO search_docs VALUES (1, ?)', [
          'searchable',
        ]);
        await a.push();
        await b.pull();
        expect(
          (await b.query(
            'SELECT id FROM search_docs WHERE fts_match(body, ?)',
            ['searchable'],
          )).rows,
          [
            [1],
          ],
        );
        await a.execute('UPDATE search_docs SET body=? WHERE id=1', [
          'updated',
        ]);
        await a.push();
        await b.pull();
        expect(
          (await b.query(
            'SELECT id FROM search_docs WHERE fts_match(body, ?)',
            ['searchable'],
          )).rows,
          isEmpty,
        );
        expect(
          (await b.query(
            'SELECT id FROM search_docs WHERE fts_match(body, ?)',
            ['updated'],
          )).rows,
          [
            [1],
          ],
        );
      } finally {
        for (final db in clients) {
          await db.close();
        }
        if (process != null) {
          process.kill();
          await process.exitCode.timeout(const Duration(seconds: 10));
        }
        await directory.delete(recursive: true);
      }
    },
    skip: available
        ? false
        : 'Install pinned server: python3 tool/install_sync_server.py',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
