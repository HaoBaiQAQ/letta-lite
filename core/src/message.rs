use serde::{Deserialize, Serialize};
use chrono::{DateTime, Utc};
use uuid::Uuid;
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum MessageRole {
    System,
    User,
    Assistant,
    Tool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub id: String,
    pub role: MessageRole,
    pub content: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<ToolCallInfo>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    pub timestamp: DateTime<Utc>,
    #[serde(default)]
    pub metadata: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCallInfo {
    pub id: String,
    pub name: String,
    pub arguments: serde_json::Value,
}

impl Message {
    pub fn system(content: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            role: MessageRole::System,
            content: content.into(),
            tool_calls: None,
            tool_call_id: None,
            timestamp: Utc::now(),
            metadata: HashMap::new(),
        }
    }
    
    pub fn user(content: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            role: MessageRole::User,
            content: content.into(),
            tool_calls: None,
            tool_call_id: None,
            timestamp: Utc::now(),
            metadata: HashMap::new(),
        }
    }
    
    pub fn assistant(content: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            role: MessageRole::Assistant,
            content: content.into(),
            tool_calls: None,
            tool_call_id: None,
            timestamp: Utc::now(),
            metadata: HashMap::new(),
        }
    }
    
    pub fn tool(tool_call_id: String, content: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            role: MessageRole::Tool,
            content: content.into(),
            tool_calls: None,
            tool_call_id: Some(tool_call_id),
            timestamp: Utc::now(),
            metadata: HashMap::new(),
        }
    }
    
    pub fn with_tool_calls(mut self, calls: Vec<ToolCallInfo>) -> Self {
        self.tool_calls = Some(calls);
        self
    }
    
    pub fn token_estimate(&self) -> usize {
        // Simple estimation: ~4 characters per token
        self.content.len() / 4
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageBuffer {
    pub messages: Vec<Message>,
    pub max_size: usize,
}

impl MessageBuffer {
    pub fn new(max_size: usize) -> Self {
        Self {
            messages: Vec::new(),
            max_size,
        }
    }
    
    pub fn push(&mut self, message: Message) {
        self.messages.push(message);
        while self.messages.len() > self.max_size {
            self.messages.remove(0);
        }
    }
    
    pub fn search(&self, query: &str, limit: usize) -> Vec<&Message> {
        self.messages
            .iter()
            .filter(|m| m.content.to_lowercase().contains(&query.to_lowercase()))
            .take(limit)
            .collect()
    }
    
    pub fn get_recent(&self, count: usize) -> Vec<&Message> {
        let start = self.messages.len().saturating_sub(count);
        self.messages[start..].iter().collect()
    }
    
    pub fn clear(&mut self) {
        self.messages.clear();
    }
}