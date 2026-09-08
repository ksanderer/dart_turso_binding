//! Private C ABI. Every handle belongs exclusively to one Dart worker isolate.
use serde::{Deserialize, Serialize};
use serde_json::{Value as Json, json};
use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use tokio::runtime::Runtime;

#[derive(Deserialize, Serialize)]
#[serde(tag = "type", content = "value", rename_all = "snake_case")]
enum Cell {
    Null,
    Integer(String),
    Real(f64),
    Text(String),
    Blob(Vec<u8>),
}

impl Cell {
    fn into_value(self) -> Result<turso::Value, String> {
        Ok(match self {
            Self::Null => turso::Value::Null,
            Self::Integer(v) => turso::Value::Integer(v.parse::<i64>().map_err(|e| e.to_string())?),
            Self::Real(v) => turso::Value::Real(v),
            Self::Text(v) => turso::Value::Text(v),
            Self::Blob(v) => turso::Value::Blob(v),
        })
    }

    fn from_value(value: turso::Value) -> Result<Self, String> {
        Ok(match value {
            turso::Value::Null => Self::Null,
            turso::Value::Integer(v) => Self::Integer(v.to_string()),
            turso::Value::Real(v) if v.is_finite() => Self::Real(v),
            turso::Value::Real(_) => return Err("Non-finite SQL real is unsupported".into()),
            turso::Value::Text(v) => Self::Text(v),
            turso::Value::Blob(v) => Self::Blob(v),
        })
    }
}

#[derive(Deserialize)]
struct Statement {
    sql: String,
    #[serde(default)]
    parameters: Vec<Cell>,
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Request {
    Open {
        path: String,
        remote_url: Option<String>,
        auth_token: Option<String>,
        #[serde(default)]
        bootstrap: bool,
    },
    Execute {
        statement: Statement,
    },
    Query {
        statement: Statement,
    },
    Batch {
        statements: Vec<Statement>,
    },
    Push,
    Pull,
    Checkpoint,
    Stats,
}

struct Database {
    connection: turso::Connection,
    // Keep the owner alive until after its connection is dropped.
    _local: Option<turso::Database>,
    sync: Option<turso::sync::Database>,
}

impl Database {
    fn synced(&self) -> Result<&turso::sync::Database, String> {
        self.sync
            .as_ref()
            .ok_or_else(|| "This is a local-only database".into())
    }
}

pub struct Session {
    database: Option<Database>,
    runtime: Runtime,
    poisoned: bool,
}

fn params(values: Vec<Cell>) -> Result<Vec<turso::Value>, String> {
    values.into_iter().map(Cell::into_value).collect()
}

fn error(e: turso::Error) -> String {
    e.to_string()
}

async fn dispatch(database: &mut Option<Database>, request: Request) -> Result<Json, String> {
    if let Request::Open {
        path,
        remote_url,
        auth_token,
        bootstrap,
    } = request
    {
        if database.is_some() {
            return Err("Database already open".into());
        }
        *database = Some(if let Some(url) = remote_url {
            let mut builder = turso::sync::Builder::new_remote(&path)
                .with_remote_url(url)
                .bootstrap_if_empty(bootstrap)
                .experimental_index_method(true);
            if let Some(token) = auth_token {
                builder = builder.with_auth_token(token);
            }
            let sync = builder.build().await.map_err(error)?;
            let connection = sync.connect().await.map_err(error)?;
            Database {
                connection,
                _local: None,
                sync: Some(sync),
            }
        } else {
            let local = turso::Builder::new_local(&path)
                .experimental_index_method(true)
                .build()
                .await
                .map_err(error)?;
            let connection = local.connect().map_err(error)?;
            Database {
                connection,
                _local: Some(local),
                sync: None,
            }
        });
        return Ok(Json::Null);
    }
    let db = database.as_mut().ok_or("Database is not open")?;
    match request {
        Request::Execute { statement } => {
            let changed = db
                .connection
                .execute(statement.sql, params(statement.parameters)?)
                .await
                .map_err(error)?;
            Ok(
                json!({"rowsAffected": changed, "lastInsertRowId": db.connection.last_insert_rowid().to_string()}),
            )
        }
        Request::Query { statement } => {
            let mut rows = db
                .connection
                .query(statement.sql, params(statement.parameters)?)
                .await
                .map_err(error)?;
            let columns = rows.column_names();
            let mut values = Vec::new();
            while let Some(row) = rows.next().await.map_err(error)? {
                let cells: Result<Vec<_>, String> = (0..columns.len())
                    .map(|i| Cell::from_value(row.get_value(i).map_err(error)?))
                    .collect();
                values.push(cells?);
            }
            Ok(json!({"columns": columns, "rows": values}))
        }
        Request::Batch { statements } => {
            // Decode all parameters before beginning the transaction.
            let statements: Result<Vec<_>, String> = statements
                .into_iter()
                .map(|s| Ok((s.sql, params(s.parameters)?)))
                .collect();
            let statements = statements?;
            let tx = db.connection.transaction().await.map_err(error)?;
            let mut counts = Vec::new();
            for (sql, parameters) in statements {
                match tx.execute(sql, parameters).await {
                    Ok(count) => counts.push(count),
                    Err(original) => {
                        return match tx.rollback().await {
                            Ok(()) => Err(error(original)),
                            Err(rollback) => {
                                Err(format!("{original}; rollback failed: {rollback}"))
                            }
                        };
                    }
                }
            }
            tx.commit().await.map_err(error)?;
            Ok(json!(counts))
        }
        Request::Push => {
            db.synced()?.push().await.map_err(error)?;
            Ok(Json::Null)
        }
        Request::Pull => Ok(json!(db.synced()?.pull().await.map_err(error)?)),
        Request::Checkpoint => {
            db.synced()?.checkpoint().await.map_err(error)?;
            Ok(Json::Null)
        }
        Request::Stats => {
            let stats = db.synced()?.stats().await.map_err(error)?;
            serde_json::to_value(stats).map_err(|e| e.to_string())
        }
        Request::Open { .. } => unreachable!(),
    }
}

/// Allocate a worker-owned session. A null pointer indicates runtime setup failure.
#[unsafe(no_mangle)]
pub extern "C" fn dtb_create() -> *mut Session {
    catch_unwind(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .map(|runtime| {
                Box::into_raw(Box::new(Session {
                    database: None,
                    runtime,
                    poisoned: false,
                }))
            })
            .unwrap_or(std::ptr::null_mut())
    })
    .unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// `session` must be a live, exclusively owned handle; `input` a NUL-terminated UTF-8 string.
/// The returned string must be released with `dtb_free` exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dtb_request(session: *mut Session, input: *const c_char) -> *mut c_char {
    let session = unsafe { &mut *session };
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<Json, String> {
        if session.poisoned {
            return Err("Native session failed; close and reopen the database".into());
        }
        let input = unsafe { CStr::from_ptr(input) }
            .to_str()
            .map_err(|e| e.to_string())?;
        let request = serde_json::from_str(input).map_err(|e| e.to_string())?;
        session
            .runtime
            .block_on(dispatch(&mut session.database, request))
    }));
    let response = match result {
        Ok(Ok(value)) => json!({"result": value}),
        Ok(Err(message)) => json!({"error": message}),
        Err(_) => {
            session.poisoned = true;
            json!({"error": "Native engine panic; close and reopen the database"})
        }
    };
    // JSON escapes embedded NULs, so this CString construction cannot fail.
    CString::new(response.to_string()).unwrap().into_raw()
}

/// # Safety
/// `value` must be a response returned by `dtb_request`, not previously freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dtb_free(value: *mut c_char) {
    drop(unsafe { CString::from_raw(value) });
}

/// # Safety
/// `session` must be a live handle with no concurrent requests, destroyed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dtb_destroy(session: *mut Session) {
    let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(session) })));
}

#[cfg(test)]
mod tests;
