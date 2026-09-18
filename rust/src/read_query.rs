//! Read-only SQL on the owning connection, including its uncommitted writes.
//! query_only alone is insufficient (Turso #8862), so validate the parsed command.
use super::{Cell, Statement};
use std::time::{Duration, Instant};
use turso_parser::{
    ast::{Cmd, Stmt},
    parser::Parser,
};
use turso_sdk_kit::rsapi::{TursoConnection, TursoStatement, TursoStatusCode};

pub(super) fn query(
    connection: &TursoConnection,
    input: Statement,
) -> Result<serde_json::Value, String> {
    if input.sql.len() > 65_536 {
        return Err("SQL text exceeds 64 KiB".into());
    }
    let mut parser = Parser::new(input.sql.as_bytes());
    let Some(Cmd::Stmt(Stmt::Select(select))) = parser.next_cmd().map_err(|e| e.to_string())?
    else {
        return Err("Read-only SQL requires a SELECT or VALUES statement".into());
    };
    if parser.next_cmd().map_err(|e| e.to_string())?.is_some() {
        return Err("Multiple SQL statements are not allowed".into());
    }
    validate_calls(&serde_json::to_value(select).map_err(|e| e.to_string())?)?;
    // The owner serializes requests, so the timeout cannot affect other work.
    let timeout = connection.get_query_timeout();
    connection.set_query_timeout(Duration::from_secs(2));
    let result = super::local::query(connection, input, true);
    connection.set_query_timeout(timeout);
    result
}

// No pragma table functions or extension/file/state-changing functions. Library
// connections also disable runtime extension loading; no user UDFs are registered.
fn validate_calls(value: &serde_json::Value) -> Result<(), String> {
    match value {
        serde_json::Value::Object(fields) => {
            for (key, value) in fields {
                if key == "TableCall" {
                    let name = value[0]["name"].as_str().unwrap_or("").to_ascii_lowercase();
                    if !matches!(name.as_str(), "json_each" | "json_tree") {
                        return Err("Only JSON table functions are allowed in read-only SQL".into());
                    }
                }
                if matches!(key.as_str(), "FunctionCall" | "FunctionCallStar") {
                    let name = value["name"].as_str().unwrap_or("").to_ascii_lowercase();
                    if matches!(
                        name.as_str(),
                        "load_extension" | "readfile" | "writefile" | "attach" | "detach"
                    ) || name.starts_with("pragma_")
                    {
                        return Err("Function is unavailable in read-only SQL".into());
                    }
                }
                validate_calls(value)?;
            }
        }
        serde_json::Value::Array(values) => {
            for value in values {
                validate_calls(value)?;
            }
        }
        _ => {}
    }
    Ok(())
}

pub(super) fn collect(
    statement: &mut TursoStatement,
    bounded: bool,
) -> Result<serde_json::Value, String> {
    let columns = (0..statement.column_count())
        .map(|i| statement.column_name(i).map_err(|e| e.to_string()))
        .collect::<Result<Vec<_>, _>>()?;
    let mut rows = Vec::new();
    let mut bytes = 0;
    let start = Instant::now();
    loop {
        if bounded && start.elapsed() > Duration::from_secs(2) {
            return Err("SQL execution time limit exceeded".into());
        }
        match statement.step(None).map_err(|e| e.to_string())? {
            TursoStatusCode::Done => break,
            TursoStatusCode::Io => statement.run_io().map_err(|e| e.to_string())?,
            TursoStatusCode::Row => {
                if bounded && rows.len() == 10_000 {
                    return Err("SQL result exceeds 10000 rows".into());
                }
                let cells = (0..columns.len())
                    .map(|i| {
                        Cell::from_value(statement.row_value(i).map_err(|e| e.to_string())?.into())
                    })
                    .collect::<Result<Vec<_>, String>>()?;
                if bounded {
                    bytes += serde_json::to_vec(&cells).map_err(|e| e.to_string())?.len();
                    if bytes > 4 * 1024 * 1024 {
                        return Err("SQL result exceeds 4 MiB".into());
                    }
                }
                rows.push(cells);
            }
        }
    }
    Ok(serde_json::json!({"columns": columns, "rows": rows}))
}
