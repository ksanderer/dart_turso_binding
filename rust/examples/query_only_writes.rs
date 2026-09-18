//! Reproduce query_only write enforcement gaps without the Dart wrapper.
//! Run: cargo run --locked --example query_only_writes
use turso::{Connection, Value};

async fn scalar(connection: &Connection, sql: &str) -> Value {
    let mut rows = connection.query(sql, ()).await.unwrap();
    rows.next().await.unwrap().unwrap().get_value(0).unwrap()
}

fn main() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("query-only.db");
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async {
        {
            let database = turso::Builder::new_local(path.to_str().unwrap())
                .build().await.unwrap();
            let writer = database.connect().unwrap();
            for sql in [
                "CREATE TABLE items(id INTEGER PRIMARY KEY)",
                "CREATE TABLE audit(id INTEGER)",
                "CREATE TRIGGER changed AFTER INSERT ON items BEGIN INSERT INTO audit VALUES (new.id); END",
            ] {
                writer.execute(sql, ()).await.unwrap();
            }
            let reader = database.connect().unwrap();
            for sql in [
                "INSERT INTO items VALUES (1)",
                "PRAGMA user_version=123",
                "PRAGMA application_id=123",
                "DROP TRIGGER changed",
            ] {
                reader.execute("PRAGMA query_only=1", ()).await.unwrap();
                assert_eq!(scalar(&reader, "PRAGMA query_only").await, Value::Integer(1));
                // Every call freshly prepares exactly one statement.
                println!("{sql}: {:?}", reader.execute(sql, ()).await);
                assert_eq!(scalar(&reader, "PRAGMA query_only").await, Value::Integer(1));
            }
        }
        // Release all original owners, then verify persisted state.
        let database = turso::Builder::new_local(path.to_str().unwrap())
            .build().await.unwrap();
        let connection = database.connect().unwrap();
        for sql in [
            "SELECT count(*) FROM items",
            "PRAGMA user_version",
            "PRAGMA application_id",
            "SELECT count(*) FROM sqlite_schema WHERE type='trigger' AND name='changed'",
        ] {
            println!("after reopen, {sql}: {:?}", scalar(&connection, sql).await);
        }
    });
}
