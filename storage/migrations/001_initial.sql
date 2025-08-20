-- Agents table
CREATE TABLE IF NOT EXISTS agents (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    system_prompt TEXT NOT NULL,
    config TEXT NOT NULL, -- JSON
    state TEXT NOT NULL,  -- JSON
    created_at TIMESTAMP NOT NULL,
    updated_at TIMESTAMP NOT NULL
);

CREATE INDEX idx_agents_name ON agents(name);
CREATE INDEX idx_agents_updated ON agents(updated_at);

-- Memory blocks table
CREATE TABLE IF NOT EXISTS blocks (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    label TEXT NOT NULL,
    description TEXT,
    value TEXT,
    limit INTEGER DEFAULT 2000,
    updated_at TIMESTAMP NOT NULL,
    FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE,
    UNIQUE(agent_id, label)
);

CREATE INDEX idx_blocks_agent ON blocks(agent_id);
CREATE INDEX idx_blocks_label ON blocks(label);

-- Messages table
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    tool_calls TEXT,      -- JSON
    tool_call_id TEXT,
    metadata TEXT,        -- JSON
    timestamp TIMESTAMP NOT NULL,
    FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
);

CREATE INDEX idx_messages_agent ON messages(agent_id);
CREATE INDEX idx_messages_timestamp ON messages(timestamp);
CREATE INDEX idx_messages_role ON messages(role);

-- Archival chunks table
CREATE TABLE IF NOT EXISTS chunks (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    folder TEXT NOT NULL,
    text TEXT NOT NULL,
    metadata TEXT,        -- JSON
    embedding BLOB,       -- Store as binary
    created_at TIMESTAMP NOT NULL,
    FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE
);

CREATE INDEX idx_chunks_agent ON chunks(agent_id);
CREATE INDEX idx_chunks_folder ON chunks(folder);
CREATE INDEX idx_chunks_created ON chunks(created_at);

-- Full-text search virtual table for chunks
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts 
USING fts5(
    text, 
    content='chunks', 
    content_rowid='rowid'
);

-- Trigger to keep FTS index in sync
CREATE TRIGGER chunks_ai AFTER INSERT ON chunks BEGIN
    INSERT INTO chunks_fts(rowid, text) VALUES (new.rowid, new.text);
END;

CREATE TRIGGER chunks_ad AFTER DELETE ON chunks BEGIN
    DELETE FROM chunks_fts WHERE rowid = old.rowid;
END;

CREATE TRIGGER chunks_au AFTER UPDATE ON chunks BEGIN
    UPDATE chunks_fts SET text = new.text WHERE rowid = new.rowid;
END;

-- Sync metadata table for cloud sync
CREATE TABLE IF NOT EXISTS sync_metadata (
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    local_version INTEGER DEFAULT 0,
    cloud_version INTEGER DEFAULT 0,
    last_sync_at TIMESTAMP,
    sync_status TEXT DEFAULT 'pending', -- 'pending', 'synced', 'conflict'
    PRIMARY KEY(entity_type, entity_id)
);

CREATE INDEX idx_sync_status ON sync_metadata(sync_status);
CREATE INDEX idx_sync_last ON sync_metadata(last_sync_at);

-- Vector clock for distributed sync
CREATE TABLE IF NOT EXISTS vector_clocks (
    device_id TEXT PRIMARY KEY,
    clock_value INTEGER NOT NULL DEFAULT 0
);