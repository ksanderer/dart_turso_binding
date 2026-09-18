//! One local connection for trusted operations and transaction-scoped SQL reads.
use super::{Cell, Json, Request, Statement, json};
use std::sync::Arc;
use turso_sdk_kit::{
    IoBackend,
    rsapi::{TursoConnection, TursoDatabase, TursoDatabaseConfig, TursoStatusCode},
};

pub(super) struct Database {
    pub connection: Arc<TursoConnection>,
    _owner: Arc<TursoDatabase>,
}

impl Database {
    pub fn open(path: String, without_rowid: bool) -> Result<Self, String> {
        let owner = TursoDatabase::new(TursoDatabaseConfig {
            path,
            experimental_features: Some(
                if without_rowid {
                    "index_method,without_rowid"
                } else {
                    "index_method"
                }
                .into(),
            ),
            async_io: false,
            encryption: None,
            vfs: IoBackend::Default,
            io: None,
            db_file: None,
            page_codec: None,
            open_flags: Default::default(),
        });
        if owner.open().map_err(|e| e.to_string())?.is_io() {
            return Err("Local database open did not complete".into());
        }
        let connection = owner.connect().map_err(|e| e.to_string())?;
        Ok(Self {
            connection,
            _owner: owner,
        })
    }

    pub fn request(&self, request: Request) -> Result<Json, String> {
        match request {
            Request::Execute { statement } => {
                let changed = execute(&self.connection, statement)?;
                Ok(
                    json!({"rowsAffected": changed, "lastInsertRowId": self.connection.last_insert_rowid().to_string()}),
                )
            }
            Request::Query { statement } => query(&self.connection, statement, false),
            Request::QueryReadOnly { statement } => {
                super::read_query::query(&self.connection, statement)
            }
            Request::Batch { statements } => {
                // Validate all parameter values before entering the transaction.
                for statement in &statements {
                    for value in &statement.parameters {
                        if let Cell::Integer(value) = value {
                            value.parse::<i64>().map_err(|e| e.to_string())?;
                        }
                    }
                }
                control(&self.connection, "BEGIN")?;
                let result = statements
                    .into_iter()
                    .map(|s| execute(&self.connection, s))
                    .collect::<Result<Vec<_>, _>>();
                match result {
                    Ok(counts) => {
                        if let Err(error) = control(&self.connection, "COMMIT") {
                            control(&self.connection, "ROLLBACK").map_err(|rollback| {
                                format!("{error}; rollback failed: {rollback}")
                            })?;
                            return Err(error);
                        }
                        Ok(json!(counts))
                    }
                    Err(error) => {
                        control(&self.connection, "ROLLBACK")
                            .map_err(|rollback| format!("{error}; rollback failed: {rollback}"))?;
                        Err(error)
                    }
                }
            }
            _ => Err("Unsupported local request".into()),
        }
    }
}

impl Drop for Database {
    fn drop(&mut self) {
        let _ = self.connection.close();
    }
}

pub(super) fn control(connection: &TursoConnection, sql: &str) -> Result<(), String> {
    execute(
        connection,
        Statement {
            sql: sql.into(),
            parameters: vec![],
        },
    )
    .map(|_| ())
}

fn prepare(
    connection: &TursoConnection,
    input: Statement,
) -> Result<Box<turso_sdk_kit::rsapi::TursoStatement>, String> {
    let mut statement = connection
        .prepare_single(input.sql)
        .map_err(|e| e.to_string())?;
    for (index, value) in input.parameters.into_iter().enumerate() {
        let result = value.into_value().and_then(|value| {
            statement
                .bind_positional(index + 1, value.into())
                .map_err(|e| e.to_string())
        });
        if let Err(error) = result {
            statement.finalize(None).map_err(|e| e.to_string())?;
            return Err(error);
        }
    }
    Ok(statement)
}

fn execute(connection: &TursoConnection, input: Statement) -> Result<i64, String> {
    let mut statement = prepare(connection, input)?;
    let result = (|| {
        loop {
            match statement.step(None).map_err(|e| e.to_string())? {
                TursoStatusCode::Done => return Ok(statement.n_change()),
                TursoStatusCode::Io => statement.run_io().map_err(|e| e.to_string())?,
                TursoStatusCode::Row => return Err("Unexpected row during execution".into()),
            }
        }
    })();
    statement.finalize(None).map_err(|e| e.to_string())?;
    result
}

pub(super) fn query(
    connection: &TursoConnection,
    input: Statement,
    bounded: bool,
) -> Result<Json, String> {
    let mut statement = prepare(connection, input)?;
    let result = super::read_query::collect(&mut statement, bounded);
    // finalize drains a running cursor; reset first, especially after a row/byte
    // budget failure, so an infinite result cannot turn rejection into more work.
    let reset = statement.reset().map_err(|e| e.to_string());
    let finalized = statement.finalize(None).map_err(|e| e.to_string());
    reset?;
    finalized?;
    result
}
