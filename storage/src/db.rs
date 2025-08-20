use std::path::{Path, PathBuf};
use rusqlite::{Connection, params, OptionalExtension};
use r2d2::{Pool, PooledConnection};
use r2d2_sqlite::SqliteConnectionManager;
use serde::{Deserialize, Serialize};
use chrono::{DateTime, Utc};
use crate::{
    error::{Result, StorageError},
    models::*,
    migrations,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StorageConfig {
    pub path: PathBuf,
    pub max_connections: u32,
}

impl Default for StorageConfig {
    fn default() -> Self {
        Self {
            path: PathBuf::from("letta.db"),
            max_connections: 5,
        }
    }
}

pub struct Storage {
    pool: Pool<SqliteConnectionManager>,
}

impl Storage {
    pub fn new(config: StorageConfig) -> Result<Self> {
        let manager = SqliteConnectionManager::file(&config.path);
        let pool = Pool::builder()
            .max_size(config.max_connections)
            .build(manager)?;
        
        // Run migrations on first connection
        let conn = pool.get()?;
        migrations::run_migrations(&conn)?;
        
        Ok(Self { pool })
    }
    
    pub fn memory() -> Result<Self> {
        let manager = SqliteConnectionManager::memory();
        let pool = Pool::builder().max_size(1).build(manager)?;
        
        let conn = pool.get()?;
        migrations::run_migrations(&conn)?;
        
        Ok(Self { pool })
    }
    
    fn conn(&self) -> Result<PooledConnection<SqliteConnectionManager>> {
        Ok(self.pool.get()?)
    }
    
    // Agent operations
    pub fn create_agent(&self, agent: &StoredAgent) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            "INSERT INTO agents (id, name, system_prompt, config, state, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                agent.id,
                agent.name,
                agent.system_prompt,
                serde_json::to_string(&agent.config)?,
                serde_json::to_string(&agent.state)?,
                agent.created_at,
                agent.updated_at,
            ],
        )?;
        Ok(())
    }
    
    pub fn get_agent(&self, id: &str) -> Result<Option<StoredAgent>> {
        let conn = self.conn()?;
        let result = conn.query_row(
            "SELECT id, name, system_prompt, config, state, created_at, updated_at
             FROM agents WHERE id = ?1",
            params![id],
            |row| {
                Ok(StoredAgent {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    system_prompt: row.get(2)?,
                    config: serde_json::from_str(&row.get::<_, String>(3)?).unwrap(),
                    state: serde_json::from_str(&row.get::<_, String>(4)?).unwrap(),
                    created_at: row.get(5)?,
                    updated_at: row.get(6)?,
                })
            },
        ).optional()?;
        Ok(result)
    }
    
    pub fn update_agent(&self, agent: &StoredAgent) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            "UPDATE agents SET name = ?2, system_prompt = ?3, config = ?4, state = ?5, updated_at = ?6
             WHERE id = ?1",
            params![
                agent.id,
                agent.name,
                agent.system_prompt,
                serde_json::to_string(&agent.config)?,
                serde_json::to_string(&agent.state)?,
                Utc::now(),
            ],
        )?;
        Ok(())
    }
    
    pub fn list_agents(&self) -> Result<Vec<StoredAgent>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT id, name, system_prompt, config, state, created_at, updated_at
             FROM agents ORDER BY updated_at DESC"
        )?;
        
        let agents = stmt.query_map([], |row| {
            Ok(StoredAgent {
                id: row.get(0)?,
                name: row.get(1)?,
                system_prompt: row.get(2)?,
                config: serde_json::from_str(&row.get::<_, String>(3)?).unwrap(),
                state: serde_json::from_str(&row.get::<_, String>(4)?).unwrap(),
                created_at: row.get(5)?,
                updated_at: row.get(6)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
        
        Ok(agents)
    }
    
    // Block operations
    pub fn upsert_block(&self, block: &StoredBlock) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            "INSERT INTO blocks (id, agent_id, label, description, value, limit, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(agent_id, label) DO UPDATE SET
                value = excluded.value,
                description = excluded.description,
                limit = excluded.limit,
                updated_at = excluded.updated_at",
            params![
                block.id,
                block.agent_id,
                block.label,
                block.description,
                block.value,
                block.limit,
                block.updated_at,
            ],
        )?;
        Ok(())
    }
    
    pub fn get_blocks(&self, agent_id: &str) -> Result<Vec<StoredBlock>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT id, agent_id, label, description, value, limit, updated_at
             FROM blocks WHERE agent_id = ?1"
        )?;
        
        let blocks = stmt.query_map(params![agent_id], |row| {
            Ok(StoredBlock {
                id: row.get(0)?,
                agent_id: row.get(1)?,
                label: row.get(2)?,
                description: row.get(3)?,
                value: row.get(4)?,
                limit: row.get(5)?,
                updated_at: row.get(6)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
        
        Ok(blocks)
    }
    
    // Message operations
    pub fn add_message(&self, message: &StoredMessage) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            "INSERT INTO messages (id, agent_id, role, content, tool_calls, tool_call_id, metadata, timestamp)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                message.id,
                message.agent_id,
                message.role,
                message.content,
                message.tool_calls.as_ref().map(|v| serde_json::to_string(v).unwrap()),
                message.tool_call_id,
                serde_json::to_string(&message.metadata)?,
                message.timestamp,
            ],
        )?;
        Ok(())
    }
    
    pub fn get_messages(&self, agent_id: &str, limit: usize) -> Result<Vec<StoredMessage>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT id, agent_id, role, content, tool_calls, tool_call_id, metadata, timestamp
             FROM messages WHERE agent_id = ?1
             ORDER BY timestamp DESC LIMIT ?2"
        )?;
        
        let messages = stmt.query_map(params![agent_id, limit], |row| {
            Ok(StoredMessage {
                id: row.get(0)?,
                agent_id: row.get(1)?,
                role: row.get(2)?,
                content: row.get(3)?,
                tool_calls: row.get::<_, Option<String>>(4)?
                    .map(|s| serde_json::from_str(&s).unwrap()),
                tool_call_id: row.get(5)?,
                metadata: serde_json::from_str(&row.get::<_, String>(6)?).unwrap(),
                timestamp: row.get(7)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
        
        Ok(messages)
    }
    
    pub fn search_messages(&self, agent_id: &str, query: &str, limit: usize) -> Result<Vec<StoredMessage>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT id, agent_id, role, content, tool_calls, tool_call_id, metadata, timestamp
             FROM messages 
             WHERE agent_id = ?1 AND content LIKE ?2
             ORDER BY timestamp DESC LIMIT ?3"
        )?;
        
        let pattern = format!("%{}%", query);
        let messages = stmt.query_map(params![agent_id, pattern, limit], |row| {
            Ok(StoredMessage {
                id: row.get(0)?,
                agent_id: row.get(1)?,
                role: row.get(2)?,
                content: row.get(3)?,
                tool_calls: row.get::<_, Option<String>>(4)?
                    .map(|s| serde_json::from_str(&s).unwrap()),
                tool_call_id: row.get(5)?,
                metadata: serde_json::from_str(&row.get::<_, String>(6)?).unwrap(),
                timestamp: row.get(7)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
        
        Ok(messages)
    }
    
    // Chunk operations
    pub fn add_chunk(&self, chunk: &StoredChunk) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            "INSERT INTO chunks (id, agent_id, folder, text, metadata, embedding, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                chunk.id,
                chunk.agent_id,
                chunk.folder,
                chunk.text,
                serde_json::to_string(&chunk.metadata)?,
                chunk.embedding.as_ref().map(|v| {
                    let bytes: Vec<u8> = v.iter().flat_map(|f| f.to_le_bytes()).collect();
                    bytes
                }),
                chunk.created_at,
            ],
        )?;
        Ok(())
    }
    
    pub fn search_chunks_fts(&self, agent_id: &str, query: &str, limit: usize) -> Result<Vec<StoredChunk>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT c.id, c.agent_id, c.folder, c.text, c.metadata, c.embedding, c.created_at
             FROM chunks c
             JOIN chunks_fts f ON c.rowid = f.rowid
             WHERE c.agent_id = ?1 AND chunks_fts MATCH ?2
             ORDER BY rank LIMIT ?3"
        )?;
        
        let chunks = stmt.query_map(params![agent_id, query, limit], |row| {
            Ok(StoredChunk {
                id: row.get(0)?,
                agent_id: row.get(1)?,
                folder: row.get(2)?,
                text: row.get(3)?,
                metadata: serde_json::from_str(&row.get::<_, String>(4)?).unwrap(),
                embedding: row.get::<_, Option<Vec<u8>>>(5)?
                    .map(|bytes| {
                        bytes.chunks(4)
                            .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
                            .collect()
                    }),
                created_at: row.get(6)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
        
        Ok(chunks)
    }
    
    // Sync operations
    pub fn get_sync_metadata(&self, entity_type: &str, entity_id: &str) -> Result<Option<SyncMetadata>> {
        let conn = self.conn()?;
        let result = conn.query_row(
            "SELECT entity_type, entity_id, local_version, cloud_version, last_sync_at, sync_status
             FROM sync_metadata WHERE entity_type = ?1 AND entity_id = ?2",
            params![entity_type, entity_id],
            |row| {
                Ok(SyncMetadata {
                    entity_type: row.get(0)?,
                    entity_id: row.get(1)?,
                    local_version: row.get(2)?,
                    cloud_version: row.get(3)?,
                    last_sync_at: row.get(4)?,
                    sync_status: row.get(5)?,
                })
            },
        ).optional()?;
        Ok(result)
    }
    
    pub fn update_sync_metadata(&self, metadata: &SyncMetadata) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            "INSERT INTO sync_metadata (entity_type, entity_id, local_version, cloud_version, last_sync_at, sync_status)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(entity_type, entity_id) DO UPDATE SET
                local_version = excluded.local_version,
                cloud_version = excluded.cloud_version,
                last_sync_at = excluded.last_sync_at,
                sync_status = excluded.sync_status",
            params![
                metadata.entity_type,
                metadata.entity_id,
                metadata.local_version,
                metadata.cloud_version,
                metadata.last_sync_at,
                metadata.sync_status,
            ],
        )?;
        Ok(())
    }
    
    // Backup and restore
    pub fn backup(&self, path: &Path) -> Result<()> {
        let conn = self.conn()?;
        let backup_conn = Connection::open(path)?;
        let backup = rusqlite::backup::Backup::new(&conn, &backup_conn)?;
        backup.run_to_completion(5, std::time::Duration::from_millis(250), None)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;
    
    #[test]
    fn test_storage_creation() {
        let storage = Storage::memory().unwrap();
        assert!(storage.list_agents().unwrap().is_empty());
    }
    
    #[test]
    fn test_agent_crud() {
        let storage = Storage::memory().unwrap();
        
        let agent = StoredAgent::new("test-agent", "Test prompt");
        storage.create_agent(&agent).unwrap();
        
        let loaded = storage.get_agent(&agent.id).unwrap().unwrap();
        assert_eq!(loaded.name, "test-agent");
        
        let agents = storage.list_agents().unwrap();
        assert_eq!(agents.len(), 1);
    }
    
    #[test]
    fn test_message_storage() {
        let storage = Storage::memory().unwrap();
        
        let agent = StoredAgent::new("test-agent", "Test prompt");
        storage.create_agent(&agent).unwrap();
        
        let message = StoredMessage::new(&agent.id, "user", "Hello");
        storage.add_message(&message).unwrap();
        
        let messages = storage.get_messages(&agent.id, 10).unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].content, "Hello");
    }
    
    #[test]
    fn test_fts_search() {
        let storage = Storage::memory().unwrap();
        
        let agent = StoredAgent::new("test-agent", "Test prompt");
        storage.create_agent(&agent).unwrap();
        
        let chunk1 = StoredChunk::new(&agent.id, "docs", "The quick brown fox");
        let chunk2 = StoredChunk::new(&agent.id, "docs", "jumps over the lazy dog");
        
        storage.add_chunk(&chunk1).unwrap();
        storage.add_chunk(&chunk2).unwrap();
        
        let results = storage.search_chunks_fts(&agent.id, "fox", 10).unwrap();
        assert_eq!(results.len(), 1);
        assert!(results[0].text.contains("fox"));
    }
}