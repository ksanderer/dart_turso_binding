# dart_turso_binding

[![CI](https://github.com/ksanderer/dart_turso_binding/actions/workflows/ci.yml/badge.svg)](https://github.com/ksanderer/dart_turso_binding/actions/workflows/ci.yml)
[![Release](https://github.com/ksanderer/dart_turso_binding/actions/workflows/release.yml/badge.svg)](https://github.com/ksanderer/dart_turso_binding/actions/workflows/release.yml)
[![pub.dev](https://img.shields.io/pub/v/dart_turso_binding.svg)](https://pub.dev/packages/dart_turso_binding)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A small, asynchronous Dart binding to the **Turso database engine**, not libSQL.
Uses the official Rust SDK with FTS and sync enabled. No Flutter dependency.

**Early development.** Do not use with irreplaceable data. A green CI badge means
those checks passed, not full SQLite compatibility or production certification.
The pub.dev badge resolves only after the first package publication.

## Installation

Until the first pub.dev release, use this Git repository and pin `ref` to a
reviewed commit:

```yaml
dependencies:
  dart_turso_binding:
    git:
      url: https://github.com/ksanderer/dart_turso_binding.git
      ref: main # Replace with a commit hash for reproducible application builds.
```

Requires Dart **3.12+**, `rustup`, and a native linker (Xcode Command Line Tools on
macOS, a C/C++ toolchain on Linux, Visual Studio C++ Build Tools and the Windows SDK
on Windows). On Windows, run from the **x64 Native Tools Command Prompt** so the
SDK resource compiler (`rc.exe`) is on PATH.
Build hooks compile the bundled Rust crate from source; no opaque prebuilt
binding binaries are downloaded. Rust **1.98.1**, the Turso Rust SDK
**0.8.0-pre.7**, resolved engine **0.8.0-pre.9**, and the native lockfile are
pinned. First builds download dependencies and can take minutes.

The Rust pin includes the LLVM Mach-O alignment fix needed by macOS 27 when
loading stripped dynamic libraries (rust-lang/rust#158410). The build hook tracks
`rust/rust-toolchain.toml` so changing the pin invalidates cached native assets.

## Usage

```dart
import 'package:dart_turso_binding/dart_turso_binding.dart';

final db = await TursoDatabase.open('notes.db'); // Or ':memory:'.
try {
  await db.execute('CREATE TABLE IF NOT EXISTS notes(body TEXT)');
  await db.execute('INSERT INTO notes VALUES (?)', ['Hello, Turso']);
  final result = await db.query('SELECT body FROM notes');
  print(result.columns);
  print(result.rows);
} finally {
  await db.close();
}
```

Atomic batches accept `List<SqlStatement>` through `db.batch(...)`; failures roll
back. Do not put transaction-control SQL inside a batch. Parameters support
`null`, signed 64-bit `int`, finite `double`, `String`, and `Uint8List`.
Column names and ordered rows preserve duplicate column names.

Interactive transactions use an exclusive `BEGIN IMMEDIATE`:

```dart
final count = await db.transaction((tx) async {
  final rows = await tx.query('SELECT COUNT(*) FROM notes');
  await tx.execute('INSERT INTO notes(body) VALUES (?)', ['Another note']);
  return rows.rows.single.single as int;
});
```

Use the callback's handle, not `db`, inside the callback. Direct database calls,
nested transactions, and `close()` inside the callback reject rather than
deadlock. Requests from outside the callback (including push/pull/checkpoint and
close) wait until it finishes. Handles expire after the callback; already
submitted handle operations drain before commit. A failed statement forces
rollback even if its error was caught. Callback and commit failures also attempt
rollback. A rollback failure rejects further work; always close the database.
Never issue transaction-control SQL through the handle.

### Sync

```dart
final db = await TursoDatabase.synced(
  path: 'replica.db',
  remoteUrl: 'https://your-sync-server',
  authToken: token, // Obtain a scoped token securely; never ship an admin token.
);
try {
  // Write locally using execute/batch, even offline.
  await db.push();
  final changed = await db.pull();
  await db.checkpoint(); // Sync-aware WAL compaction.
  final stats = await db.stats();
} finally {
  await db.close(); // Does not push automatically.
}
```

First open starts empty unless `bootstrap: true` is requested. Sync uses upstream
push/pull semantics, **not CRDT merging**; conflicts use last-push-wins. Static
authentication tokens require closing/reopening to rotate. Sync methods reject
local-only databases. Tests cover FTS after remote inserts and updates against the
pinned local sync server. Cloud authentication and server configuration still
require separate validation; local-server tests are not a Turso Cloud certification.

### Full-text search

```sql
CREATE INDEX notes_fts ON notes USING fts (body);
SELECT body FROM notes WHERE fts_match(body, 'hello');
```

Turso uses Tantivy, **not SQLite FTS5**. Search syntax, tokenization, and transaction
visibility differ. FTS remains experimental upstream.

## Execution and platform coverage

One dedicated worker isolate owns each database and connection. SQL, filesystem,
and network waits do not block the caller isolate. Requests execute in order;
batches and transaction callbacks cannot interleave with other requests.
`close()` drains submitted work and explicitly frees native resources.
Always close databases, including on errors.

| Target | CI scope |
| --- | --- |
| macOS ARM64, Linux x64, Windows x64 | Dart runtime and local sync integration tests |
| iOS 13+ ARM64 device/simulator | Native cross-build only; no device/runtime claim |
| Android ARM64 | Native cross-build only; no device/runtime claim |
| Other architectures, web | Not covered / not supported in this release |

Mobile native compilation does **not** yet certify Flutter packaging, app signing,
background execution, or store distribution. Check the linked CI run for actual
results; a configured job is not a passing test.

**Not provided:** streaming cursors, cancellation, named parameters,
exposed prepared-statement handles, partial sync, encryption
configuration, multi-process coordination, or compatibility with `sqlite3` handles.
Queries buffer all rows and use a private tagged JSON FFI transport: use SQL LIMIT
for large results; this is not a zero-copy analytics binding. Never independently
write the same synced file through another database driver.

## Bounded query-only execution

`await db.queryReadOnly(sql, parameters)` and `await tx.queryReadOnly(...)`
execute on the **owning local connection**, including in-memory databases.
The transaction variant sees uncommitted writes. Synced databases are unsupported.
Ordinary `query()` remains unrestricted.

The Turso parser must accept exactly one SELECT/VALUES command, including CTEs.
DML, DDL, PRAGMA, transaction control and additional statements are rejected
before preparation. File/extension/state-changing function calls are blocked;
only `json_each` and `json_tree` table calls are supported. Runtime extension
loading is disabled on library connections; no user UDFs are registered.
This deliberately does not rely on `query_only=1`, whose write gaps are tracked
in [Turso #8862](https://github.com/tursodatabase/turso/issues/8862).

Queries reject SQL over 64 KiB and results over 10,000 rows or 4 MiB of serialized
row cells. Native execution has a two-second timeout. Failures never return
successful partial results. These bounds are not a hard memory limit on a single
expression or an interruption guarantee during preparation. Statements are
finalized and the previous connection timeout restored on success and failure.

Use `tx.savepoint((operation) => operation.queryReadOnly(...))` to isolate a
caught query failure. An engine failure that aborts the enclosing transaction
still aborts the invocation; it must not silently resume in autocommit.

Production regressions are in `test/read_query_test.dart` and
`test/transaction_read_query_test.dart`. The historical upstream reproducers
in `rust/tests/query_only_scheme.rs` and `rust/examples/query_only_writes.rs`
exercise the old query_only flag approach, not this guarded API; three assertions
in that experimental Rust suite intentionally fail on the pinned upstream version.

The separate `read_only(true)` registry-reuse problem is already tracked in
[Turso #6031](https://github.com/tursodatabase/turso/issues/6031).
[PR #6066](https://github.com/tursodatabase/turso/pull/6066) was closed without
merging; it is not a shipped fix for that problem.

## Development and releases

```sh
dart pub get
python3 tool/install_sync_server.py  # Pinned CLI, SHA-256 verified.
dart test
dart analyze
```

Without the test server, the sync test is explicitly skipped; CI requires it.
Native checks: `cargo fmt --check`, `cargo clippy --locked -- -D warnings`, and
`cargo test --locked` from `rust/`.

For a release, update the versions in `pubspec.yaml` and `rust/Cargo.toml`, refresh
`rust/Cargo.lock`, and add a changelog entry. Push `v<version>`. The release workflow
validates metadata, runs CI, dry-runs publication, publishes through pub.dev OIDC,
and creates a GitHub release. Published packages include native source and the
lockfile, not platform binaries. The first pub.dev upload requires an authorized
account; then enable GitHub publishing for `ksanderer/dart_turso_binding` with tag
pattern `v{{version}}` in the package's pub.dev Admin settings.

Independent community project; not an official Turso SDK. [MIT](LICENSE).
