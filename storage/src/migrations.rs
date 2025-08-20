use rusqlite::Connection;
use crate::error::Result;

const MIGRATIONS: &[(&str, &str)] = &[
    ("001_initial", include_str!("../migrations/001_initial.sql")),
];

pub fn run_migrations(conn: &Connection) -> Result<()> {
    // Create migrations table if it doesn't exist
    conn.execute(
        "CREATE TABLE IF NOT EXISTS migrations (
            name TEXT PRIMARY KEY,
            applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )",
        [],
    )?;
    
    // Get applied migrations
    let mut stmt = conn.prepare("SELECT name FROM migrations")?;
    let applied: Vec<String> = stmt
        .query_map([], |row| row.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    
    // Apply new migrations
    for (name, sql) in MIGRATIONS {
        if !applied.contains(&name.to_string()) {
            tracing::info!("Applying migration: {}", name);
            conn.execute_batch(sql)?;
            conn.execute(
                "INSERT INTO migrations (name) VALUES (?)",
                [name],
            )?;
        }
    }
    
    Ok(())
}