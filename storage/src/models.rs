use serde::{Deserialize, Serialize};
use chrono::{DateTime, Utc};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredAgent {
    pub id: String,
    pub name: String,
    pub system_prompt: String,
    pub config: serde_json::Value,
    pub state: serde_json::Value,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredMessage {
    pub id: String,
    pub agent_id: String,
    pub role: String,
    pub content: String,
    pub tool_calls: Option<serde_json::Value>,
    pub tool_call_id: Option<String>,
    pub metadata: serde_json::Value,
    pub timestamp: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredBlock {
    pub id: String,
    pub agent_id: String,
    pub label: String,
    pub description: String,
    pub value: String,
    pub limit: i32,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredChunk {
    pub id: String,
    pub agent_id: String,
    pub folder: String,
    pub text: String,
    pub metadata: serde_json::Value,
    pub embedding: Option<Vec<f32>>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncMetadata {
    pub entity_type: String,
    pub entity_id: String,
    pub local_version: i64,
    pub cloud_version: i64,
    pub last_sync_at: DateTime<Utc>,
    pub sync_status: String,
}

impl StoredAgent {
    pub fn new(name: impl Into<String>, system_prompt: impl Into<String>) -> Self {
        let now = Utc::now();
        Self {
            id: Uuid::new_v4().to_string(),
            name: name.into(),
            system_prompt: system_prompt.into(),
            config: serde_json::json!({}),
            state: serde_json::json!({}),
            created_at: now,
            updated_at: now,
        }
    }
}

impl StoredMessage {
    pub fn new(agent_id: impl Into<String>, role: impl Into<String>, content: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            agent_id: agent_id.into(),
            role: role.into(),
            content: content.into(),
            tool_calls: None,
            tool_call_id: None,
            metadata: serde_json::json!({}),
            timestamp: Utc::now(),
        }
    }
}

impl StoredBlock {
    pub fn new(agent_id: impl Into<String>, label: impl Into<String>, value: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            agent_id: agent_id.into(),
            label: label.into(),
            description: String::new(),
            value: value.into(),
            limit: 2000,
            updated_at: Utc::now(),
        }
    }
}

impl StoredChunk {
    pub fn new(agent_id: impl Into<String>, folder: impl Into<String>, text: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            agent_id: agent_id.into(),
            folder: folder.into(),
            text: text.into(),
            metadata: serde_json::json!({}),
            embedding: None,
            created_at: Utc::now(),
        }
    }
}