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
macOS, a C/C++ toolchain on Linux, Visual Studio C++ Build Tools on Windows).
Build hooks compile the bundled Rust crate from source; no opaque prebuilt
binding binaries are downloaded. Rust **1.95.0**, Turso **0.7.2**, and the native
lockfile are pinned. First builds download dependencies and can take minutes.

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
batches cannot interleave with other requests. `close()` drains submitted work
and explicitly frees native resources. Always close databases, including on errors.

| Target | CI scope |
| --- | --- |
| macOS ARM64, Linux x64, Windows x64 | Dart runtime and local sync integration tests |
| iOS 13+ ARM64 device/simulator | Native cross-build only; no device/runtime claim |
| Android ARM64 | Native cross-build only; no device/runtime claim |
| Other architectures, web | Not covered / not supported in this release |

Mobile native compilation does **not** yet certify Flutter packaging, app signing,
background execution, or store distribution. Check the linked CI run for actual
results; a configured job is not a passing test.

**Not provided:** streaming cursors, interactive transaction callbacks, cancellation,
named parameters, exposed prepared-statement handles, partial sync, encryption
configuration, multi-process coordination, or compatibility with `sqlite3` handles.
Queries buffer all rows and use a private tagged JSON FFI transport: use SQL LIMIT
for large results; this is not a zero-copy analytics binding. Never independently
write the same synced file through another database driver.

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
