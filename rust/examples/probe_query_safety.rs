use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    let directory = std::env::temp_dir().join(format!(
        "turso-safety-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir(&directory).unwrap();
    let path = directory.join("probe.db");
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async {
        let owner = turso::Builder::new_local(path.to_str().unwrap())
            .build()
            .await
            .unwrap();
        let writer = owner.connect().unwrap();
        writer
            .execute("CREATE TABLE items(id INTEGER PRIMARY KEY)", ())
            .await
            .unwrap();
        writer
            .execute("INSERT INTO items VALUES (1)", ())
            .await
            .unwrap();
        let read_owner = turso::Builder::new_local(path.to_str().unwrap())
            .read_only(true)
            .build()
            .await;
        match read_owner {
            Ok(read_owner) => {
                let reader = read_owner.connect().unwrap();
                println!(
                    "read-only alongside writer: read {:?}",
                    reader.query("SELECT id FROM items", ()).await.is_ok()
                );
                println!(
                    "read-only alongside writer: write {:?}",
                    reader.execute("UPDATE items SET id=2", ()).await
                );
                println!(
                    "read-only: query_only=0 {:?}",
                    reader.execute("PRAGMA query_only=0", ()).await
                );
                println!(
                    "read-only after query_only=0: write {:?}",
                    reader.execute("UPDATE items SET id=3", ()).await
                );
            }
            Err(error) => println!("read-only alongside writer: open rejected: {error}"),
        }
        {
            let mut rows = writer.query("SELECT id FROM items", ()).await.unwrap();
            let row = rows.next().await.unwrap().unwrap();
            println!("value observed by writer: {:?}", row.get_value(0).unwrap());
        }
        drop(writer);
        drop(owner);
        let read_owner = turso::Builder::new_local(path.to_str().unwrap())
            .read_only(true)
            .build()
            .await
            .unwrap();
        let reader = read_owner.connect().unwrap();
        println!(
            "read-only after writer close: write {:?}",
            reader.execute("UPDATE items SET id=4", ()).await
        );
        println!(
            "read-only after writer close: query_only=0 {:?}",
            reader.execute("PRAGMA query_only=0", ()).await
        );
        println!(
            "read-only after disabling query_only: write {:?}",
            reader.execute("UPDATE items SET id=5", ()).await
        );
    });
    drop(runtime);
    std::fs::remove_dir_all(directory).unwrap();
}
