//! Experimental contract tests, NOT a production read-only implementation.
//! Run: cargo test --locked --test query_only_scheme -- --nocapture
//!
//! The SDK kit is the same version already resolved by the production binding.
//! It exposes prepare_first/tail position, which the high-level turso API hides.
//! No SELECT allowlist is added: these tests assess the user's proposed scheme.

use std::sync::{Arc, Mutex};
use std::time::Duration;
use tempfile::TempDir;
use turso::Value;
use turso_parser::{lexer::Lexer, token::TokenType};
use turso_sdk_kit::IoBackend;
use turso_sdk_kit::rsapi::{
    TursoConnection, TursoDatabase, TursoDatabaseConfig, TursoStatement, TursoStatusCode,
};

type Rows = Vec<Vec<Value>>;

#[derive(Debug)]
struct Failure {
    stage: &'static str,
    message: String,
}

fn failure(stage: &'static str, error: impl std::fmt::Display) -> Failure {
    Failure {
        stage,
        message: error.to_string(),
    }
}

// Serialize the ENTIRE sequence, not individual SDK calls. No transaction or
// rollback is used to hide effects of SQL submitted through the candidate API.
struct SchemeReader(Mutex<Arc<TursoConnection>>);

impl SchemeReader {
    fn query(&self, sql: &str, parameters: &[Value]) -> Result<Rows, Failure> {
        let connection = self.0.lock().unwrap();
        validate_single(&connection, sql)?;
        execute(&connection, "PRAGMA query_only=1", &[])
            .map_err(|e| failure("enable query_only", e))?;
        // Fresh prepare of the ORIGINAL SQL, not execution of the validation
        // statement. This distinction is what the experiment must preserve.
        let statement = connection
            .prepare_single(sql)
            .map_err(|e| failure("protected prepare", e))?;
        collect(*statement, parameters).map_err(|e| failure("execute", e))
    }
}

fn validate_single(connection: &TursoConnection, sql: &str) -> Result<(), Failure> {
    let (mut statement, position) = connection
        .prepare_first(sql)
        .map_err(|e| failure("validation prepare", e))?
        .ok_or_else(|| failure("empty SQL", "expected one statement"))?;
    // Lex ONLY the tail, using the engine's lexer. Never prepare or execute it.
    let result = Lexer::new(&sql.as_bytes()[position..]).try_for_each(|token| {
        let token = token.map_err(|e| failure("tail", e))?;
        if token.token_type != TokenType::TK_NONE {
            return Err(failure("tail", "additional SQL after the first statement"));
        }
        Ok(())
    });
    let finalized = statement
        .finalize(None)
        .map_err(|e| failure("validation finalize", e))?;
    assert_eq!(
        finalized,
        TursoStatusCode::Done,
        "unexecuted statement must finalize without IO"
    );
    result
}

fn collect(mut statement: TursoStatement, parameters: &[Value]) -> Result<Rows, String> {
    let result = (|| {
        for (index, value) in parameters.iter().enumerate() {
            statement
                .bind_positional(index + 1, value.clone().into())
                .map_err(|e| e.to_string())?;
        }
        let mut rows = Vec::new();
        loop {
            match statement.step(None).map_err(|e| e.to_string())? {
                TursoStatusCode::Row => {
                    assert!(rows.len() < 10_000, "test harness row budget exceeded");
                    rows.push(
                        (0..statement.column_count())
                            .map(|index| {
                                statement
                                    .row_value(index)
                                    .map(Value::from)
                                    .map_err(|e| e.to_string())
                            })
                            .collect::<Result<Vec<_>, _>>()?,
                    );
                }
                TursoStatusCode::Io => statement.run_io().map_err(|e| e.to_string())?,
                TursoStatusCode::Done => break,
            }
        }
        Ok(rows)
    })();
    // Reset before finalization: finalize itself can drain a running statement.
    // Cleanup errors must not be swallowed or turn a failed query into success.
    statement
        .reset()
        .map_err(|e| format!("reset failed after {result:?}: {e}"))?;
    let status = statement.finalize(None).map_err(|e| e.to_string())?;
    assert_eq!(status, TursoStatusCode::Done);
    result
}

fn execute(connection: &TursoConnection, sql: &str, parameters: &[Value]) -> Result<Rows, String> {
    collect(
        *connection.prepare_single(sql).map_err(|e| e.to_string())?,
        parameters,
    )
}

struct Fixture {
    reader: SchemeReader,
    writer: Arc<TursoConnection>,
    _database: Arc<TursoDatabase>,
    directory: TempDir,
}

impl Fixture {
    fn new() -> Self {
        Self::open(tempfile::tempdir().unwrap(), true)
    }

    fn open(directory: TempDir, initialize: bool) -> Self {
        let database = TursoDatabase::new(TursoDatabaseConfig {
            path: directory.path().join("probe.db").to_str().unwrap().into(),
            experimental_features: Some("index_method".into()),
            // Synchronous IO driving makes the integration harness independent
            // of Tokio scheduling; the underlying engine/SQL paths are unchanged.
            async_io: false,
            encryption: None,
            vfs: IoBackend::Default,
            io: None,
            db_file: None,
            page_codec: None,
            open_flags: Default::default(),
        });
        assert!(!database.open().unwrap().is_io());
        let writer = database.connect().unwrap();
        execute(&writer, "PRAGMA foreign_keys=1", &[]).unwrap();
        if initialize {
            for sql in [
                "CREATE TABLE items(id INTEGER PRIMARY KEY, title TEXT NOT NULL)",
                "INSERT INTO items VALUES (1, 'original')",
                "CREATE TABLE audit(value TEXT)",
                "CREATE TRIGGER changed AFTER UPDATE ON items BEGIN INSERT INTO audit VALUES ('changed'); END",
            ] {
                execute(&writer, sql, &[]).unwrap();
            }
        }
        let reader = database.connect().unwrap();
        for connection in [&reader, &writer] {
            connection.set_busy_timeout(Duration::from_millis(200));
            connection.set_query_timeout(Duration::from_secs(2));
        }
        Self {
            reader: SchemeReader(Mutex::new(reader)),
            writer,
            _database: database,
            directory,
        }
    }

    fn reopen(self) -> Self {
        let Self {
            reader,
            writer,
            _database,
            directory,
        } = self;
        reader.0.lock().unwrap().close().unwrap();
        writer.close().unwrap();
        drop(reader);
        drop(writer);
        drop(_database);
        Self::open(directory, false)
    }

    fn snapshot(&self) -> Vec<Result<Rows, String>> {
        [
            "SELECT * FROM items ORDER BY id",
            "SELECT * FROM audit ORDER BY rowid",
            "SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY type, name",
            "PRAGMA user_version",
            "PRAGMA application_id",
            "PRAGMA schema_version",
            "PRAGMA foreign_keys",
            "PRAGMA query_only",
        ]
        .into_iter()
        .map(|sql| execute(&self.writer, sql, &[]))
        .collect()
    }

    fn assert_unchanged(&self, before: &[Result<Rows, String>], sql: &str) {
        assert_eq!(
            self.snapshot(),
            before,
            "persistent data/schema or writer settings changed: {sql}"
        );
    }
}

#[test]
fn reads_accept_literals_comments_ctes_and_bound_values() {
    let fixture = Fixture::new();
    let before = fixture.snapshot();
    for sql in [
        "SELECT title FROM items",
        "SELECT title FROM items;",
        "SELECT title FROM items;;",
        "-- leading ; comment\nSELECT title FROM items; -- trailing ; comment",
        "/* DELETE FROM items; */ SELECT title FROM items; /* another ; comment */",
        "WITH selected AS (SELECT title FROM items) SELECT title FROM selected",
    ] {
        assert_eq!(
            fixture.reader.query(sql, &[]).unwrap(),
            vec![vec![Value::from("original")]],
            "{sql}"
        );
    }
    let values = vec![
        Value::Null,
        Value::Integer(i64::MAX),
        Value::Real(1.25),
        Value::from("Привет; ' /* SQL */ \0"),
        Value::Blob(vec![0, 255]),
    ];
    assert_eq!(
        fixture
            .reader
            .query("SELECT ?1, ?2, ?3, ?4, ?5; -- tail", &values)
            .unwrap(),
        vec![values]
    );
    assert_eq!(
        fixture
            .reader
            .query("SELECT '; DELETE FROM items' AS \"semi;colon\"", &[])
            .unwrap(),
        vec![vec![Value::from("; DELETE FROM items")]]
    );
    fixture.assert_unchanged(&before, "valid reads");
}

#[test]
fn multiple_statements_are_rejected_before_executing_either_statement() {
    for sql in [
        "SELECT 1; DELETE FROM items",
        "UPDATE items SET title='bad'; SELECT 1",
        "PRAGMA query_only=0; UPDATE items SET title='bad'",
        "SELECT 'Привет;'; /* hide ; */ DELETE FROM items",
        "SELECT 1; -- hide\nDELETE FROM items",
        "SELECT 1; /* outer /* inner */ DELETE FROM items; -- */",
        "SELECT 1; PRAGMA user_version=123",
        "PRAGMA user_version=123; SELECT 1",
        "CREATE TABLE injected(value TEXT); SELECT 1",
        "SELECT 1; invalid sql",
        "SELECT 1;; DELETE FROM items",
    ] {
        let fixture = Fixture::new();
        let before = fixture.snapshot();
        let error = fixture
            .reader
            .query(sql, &[])
            .expect_err(&format!("accepted multiple statements: {sql:?}"));
        assert_eq!(
            error.stage, "tail",
            "wrong rejection stage for {sql}: {error:?}"
        );
        fixture.assert_unchanged(&before, sql);
        assert_eq!(
            fixture.reader.query("SELECT 42", &[]).unwrap(),
            vec![vec![Value::Integer(42)]]
        );
    }
}

#[test]
fn empty_and_malformed_sql_fail_without_poisoning_reader() {
    let fixture = Fixture::new();
    let before = fixture.snapshot();
    for sql in [
        "",
        " \n\t",
        "-- only comment",
        "/* comment */",
        ";",
        "not SQL",
        "SELECT '",
        "SELECT * FROM missing",
        "SELECT 1;\0DELETE FROM items",
    ] {
        assert!(fixture.reader.query(sql, &[]).is_err(), "accepted {sql:?}");
        fixture.assert_unchanged(&before, sql);
        assert!(fixture.reader.query("SELECT 1", &[]).is_ok());
    }
}

// Each case must first SUCCEED on a control writer, so unsupported SQL cannot
// accidentally be counted as evidence that the scheme prevents writes.
macro_rules! write_case {
    ($name:ident, $sql:expr) => {
        #[test]
        fn $name() {
            let control = Fixture::new();
            let baseline = control.snapshot();
            execute(&control.writer, $sql, &[]).expect("control SQL must be supported");
            assert_ne!(
                control.snapshot(),
                baseline,
                "control SQL must really mutate state"
            );

            let fixture = Fixture::new();
            let before = fixture.snapshot();
            let result = fixture.reader.query($sql, &[]);
            execute(&fixture.writer, "UPDATE items SET title=title WHERE 0", &[])
                .expect("original writer must remain usable before closing connections");
            // Also verify durable state after releasing ALL owners and reopening
            // the file. Neither cached results nor rollback can hide a write.
            let observed = fixture.snapshot();
            let fixture = fixture.reopen();
            assert_eq!(
                fixture.snapshot(),
                observed,
                "reopen changed observed state"
            );
            assert_eq!(
                observed, before,
                "scheme changed durable state for {}: {result:?}",
                $sql
            );
            let error = result.expect_err("read-only scheme accepted a write");
            assert!(
                matches!(error.stage, "protected prepare" | "execute"),
                "not rejected by query_only: {error:?}"
            );
            assert!(
                error.message.to_ascii_lowercase().contains("query_only")
                    || error.message.to_ascii_lowercase().contains("readonly")
                    || error.message.to_ascii_lowercase().contains("read-only"),
                "unrelated error is not evidence of protection: {error:?}"
            );
            // A denied query must not make the main writer read-only or leave locks.
            execute(
                &fixture.writer,
                "INSERT INTO items VALUES (2, 'writer still works')",
                &[],
            )
            .unwrap();
            assert_eq!(
                fixture
                    .reader
                    .query("SELECT title FROM items WHERE id=2", &[])
                    .unwrap(),
                vec![vec![Value::from("writer still works")]]
            );
        }
    };
}

write_case!(blocks_insert, "INSERT INTO items VALUES (2, 'bad')");
write_case!(blocks_update_and_trigger, "UPDATE items SET title='bad'");
write_case!(blocks_delete, "DELETE FROM items");
write_case!(blocks_replace, "REPLACE INTO items VALUES (1, 'bad')");
write_case!(
    blocks_upsert,
    "INSERT INTO items VALUES (1, 'bad') ON CONFLICT(id) DO UPDATE SET title=excluded.title"
);
write_case!(
    blocks_returning,
    "UPDATE items SET title='bad' RETURNING id"
);
write_case!(
    blocks_cte_update,
    "WITH selected AS (SELECT 1 AS id) UPDATE items SET title='bad' WHERE id IN (SELECT id FROM selected)"
);
write_case!(
    blocks_cte_delete,
    "WITH selected AS (SELECT 1 AS id) DELETE FROM items WHERE id IN (SELECT id FROM selected)"
);
write_case!(blocks_create_table, "CREATE TABLE injected(value TEXT)");
write_case!(blocks_drop_table, "DROP TABLE items");
write_case!(
    blocks_alter_table,
    "ALTER TABLE items ADD COLUMN extra TEXT"
);
write_case!(blocks_create_index, "CREATE INDEX injected ON items(title)");
write_case!(blocks_drop_trigger, "DROP TRIGGER changed");
write_case!(
    blocks_create_trigger,
    "CREATE TRIGGER injected AFTER INSERT ON items BEGIN INSERT INTO audit VALUES ('first'); INSERT INTO audit VALUES ('second'); END"
);
write_case!(blocks_user_version, "PRAGMA user_version=123");
write_case!(blocks_application_id, "PRAGMA application_id=123");

#[test]
fn repeated_calls_rearm_after_successful_and_rejected_query_only_disable() {
    let fixture = Fixture::new();
    let before = fixture.snapshot();
    for _ in 0..4 {
        fixture.reader.query("PRAGMA query_only=0", &[]).unwrap();
        // The proposal allows this single pragma. Verify that it really disabled
        // the flag, rather than obtaining a false pass from a no-op.
        assert_eq!(
            execute(&fixture.reader.0.lock().unwrap(), "PRAGMA query_only", &[]).unwrap(),
            vec![vec![Value::Integer(0)]]
        );
        let error = fixture
            .reader
            .query("UPDATE items SET title='bad'", &[])
            .unwrap_err();
        assert_eq!(error.stage, "protected prepare");
        let error = fixture
            .reader
            .query("PRAGMA query_only=0; DELETE FROM items", &[])
            .unwrap_err();
        assert_eq!(error.stage, "tail");
        // Rejection can leave query_only off during validation. Next call must
        // nevertheless rearm and reprepare; it must not reuse validation bytecode.
        assert!(fixture.reader.query("DELETE FROM items", &[]).is_err());
        fixture.assert_unchanged(&before, "query_only disable sequences");
    }
}

#[test]
fn validation_prepare_is_not_side_effect_free() {
    let fixture = Fixture::new();
    let connection = fixture.reader.0.lock().unwrap();
    execute(&connection, "PRAGMA query_only=1", &[]).unwrap();
    assert_eq!(
        validate_single(&connection, "PRAGMA query_only=0; SELECT 1")
            .unwrap_err()
            .stage,
        "tail"
    );
    assert_eq!(
        execute(&connection, "PRAGMA query_only", &[]).unwrap(),
        vec![vec![Value::Integer(0)]]
    );
    assert_eq!(
        execute(&fixture.writer, "PRAGMA query_only", &[]).unwrap(),
        vec![vec![Value::Integer(0)]]
    );
}

#[test]
fn concurrent_submissions_cannot_interleave_validation_rearming_and_execution() {
    let fixture = Fixture::new();
    let before = fixture.snapshot();
    std::thread::scope(|scope| {
        for _ in 0..4 {
            let reader = &fixture.reader;
            scope.spawn(move || {
                for _ in 0..10 {
                    reader.query("PRAGMA query_only=0", &[]).unwrap();
                    assert!(reader.query("UPDATE items SET title='bad'", &[]).is_err());
                    assert!(reader.query("SELECT title FROM items", &[]).is_ok());
                }
            });
        }
    });
    fixture.assert_unchanged(&before, "concurrent calls");
}

#[test]
fn runtime_errors_release_statements_and_reader_recovers() {
    let fixture = Fixture::new();
    assert!(
        fixture
            .reader
            .query("SELECT json('not json')", &[])
            .is_err()
    );
    assert!(
        fixture
            .reader
            .query("SELECT ?1", &[Value::from("safe")])
            .is_ok()
    );
    execute(&fixture.writer, "UPDATE items SET title='committed'", &[]).unwrap();
    assert_eq!(
        fixture
            .reader
            .query("SELECT title FROM items", &[])
            .unwrap(),
        vec![vec![Value::from("committed")]]
    );
}

#[test]
fn ambient_extension_and_attach_are_unavailable_in_current_binding_configuration() {
    let fixture = Fixture::new();
    let before = fixture.snapshot();
    let attachment = fixture.directory.path().join("outside.db");
    let output = fixture.directory.path().join("export.db");
    for sql in [
        format!("ATTACH DATABASE '{}' AS outside", attachment.display()),
        format!("VACUUM INTO '{}'", output.display()),
        "SELECT load_extension('not-an-extension')".into(),
    ] {
        let result = fixture.reader.query(&sql, &[]);
        assert!(result.is_err(), "unexpectedly accepted {sql}: {result:?}");
        fixture.assert_unchanged(&before, &sql);
    }
    assert!(!attachment.exists());
    assert!(!output.exists());
}

#[test]
fn validation_alone_does_not_change_persistent_data_or_schema() {
    for sql in [
        "UPDATE items SET title='bad'",
        "DROP TRIGGER changed",
        "DROP TABLE items",
        "CREATE TABLE injected(value TEXT)",
        "PRAGMA user_version=123",
        "PRAGMA application_id=123",
    ] {
        let fixture = Fixture::new();
        let before = fixture.snapshot();
        validate_single(&fixture.reader.0.lock().unwrap(), sql).unwrap();
        fixture.assert_unchanged(&before, sql);
        fixture.reopen().assert_unchanged(&before, sql);
    }
}

#[test]
fn closed_reader_fails_closed_and_does_not_affect_writer() {
    let fixture = Fixture::new();
    let before = fixture.snapshot();
    fixture.reader.0.lock().unwrap().close().unwrap();
    assert!(
        fixture
            .reader
            .query("UPDATE items SET title='bad'", &[])
            .is_err()
    );
    fixture.assert_unchanged(&before, "closed reader");
    execute(&fixture.writer, "UPDATE items SET title='writer'", &[]).unwrap();
}
