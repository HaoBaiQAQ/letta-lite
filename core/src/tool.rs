use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use crate::error::{LettaError, Result};
use crate::agent::AgentState;
use async_trait::async_trait;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolSchema {
    pub name: String,
    pub description: String,
    pub parameters: Value,
    #[serde(default)]
    pub required: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tool {
    pub schema: ToolSchema,
    #[serde(skip)]
    pub handler: Option<Box<dyn ToolHandler>>,
}

impl Tool {
    pub fn new(name: impl Into<String>, description: impl Into<String>) -> Self {
        Self {
            schema: ToolSchema {
                name: name.into(),
                description: description.into(),
                parameters: serde_json::json!({
                    "type": "object",
                    "properties": {}
                }),
                required: vec![],
            },
            handler: None,
        }
    }
    
    pub fn with_parameters(mut self, params: Value) -> Self {
        self.schema.parameters = params;
        self
    }
    
    pub fn with_required(mut self, required: Vec<String>) -> Self {
        self.schema.required = required;
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolResult {
    pub success: bool,
    pub result: Value,
    #[serde(default)]
    pub request_heartbeat: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl ToolResult {
    pub fn success(result: Value) -> Self {
        Self {
            success: true,
            result,
            request_heartbeat: false,
            error: None,
        }
    }
    
    pub fn error(message: impl Into<String>) -> Self {
        Self {
            success: false,
            result: Value::Null,
            request_heartbeat: false,
            error: Some(message.into()),
        }
    }
    
    pub fn with_heartbeat(mut self) -> Self {
        self.request_heartbeat = true;
        self
    }
}

pub trait ToolHandler: Send + Sync {
    fn execute(&self, args: &Value, state: &mut AgentState) -> Result<ToolResult>;
}

// Built-in tool handlers
pub struct MemoryReplaceHandler;
pub struct MemoryAppendHandler;
pub struct ArchivalInsertHandler;
pub struct ArchivalSearchHandler;
pub struct ConversationSearchHandler;

impl ToolHandler for MemoryReplaceHandler {
    fn execute(&self, args: &Value, state: &mut AgentState) -> Result<ToolResult> {
        let label = args.get("label")
            .and_then(|v| v.as_str())
            .ok_or_else(|| LettaError::ToolExecution("Missing 'label' parameter".into()))?;
        
        let value = args.get("value")
            .and_then(|v| v.as_str())
            .ok_or_else(|| LettaError::ToolExecution("Missing 'value' parameter".into()))?;
        
        state.memory.set_block(label, value)?;
        
        Ok(ToolResult::success(serde_json::json!({
            "status": "success",
            "message": format!("Updated memory block '{}'", label)
        })))
    }
}

impl ToolHandler for MemoryAppendHandler {
    fn execute(&self, args: &Value, state: &mut AgentState) -> Result<ToolResult> {
        let label = args.get("label")
            .and_then(|v| v.as_str())
            .ok_or_else(|| LettaError::ToolExecution("Missing 'label' parameter".into()))?;
        
        let text = args.get("text")
            .and_then(|v| v.as_str())
            .ok_or_else(|| LettaError::ToolExecution("Missing 'text' parameter".into()))?;
        
        state.memory.append_block(label, text)?;
        
        Ok(ToolResult::success(serde_json::json!({
            "status": "success",
            "message": format!("Appended to memory block '{}'", label)
        })))
    }
}

impl ToolHandler for ArchivalInsertHandler {
    fn execute(&self, args: &Value, state: &mut AgentState) -> Result<ToolResult> {
        let folder = args.get("folder")
            .and_then(|v| v.as_str())
            .unwrap_or("default");
        
        let text = args.get("text")
            .and_then(|v| v.as_str())
            .ok_or_else(|| LettaError::ToolExecution("Missing 'text' parameter".into()))?;
        
        // This will be handled by storage layer
        state.archival_entries.push(serde_json::json!({
            "folder": folder,
            "text": text,
            "timestamp": chrono::Utc::now()
        }));
        
        Ok(ToolResult::success(serde_json::json!({
            "status": "success",
            "message": "Added to archival memory"
        })))
    }
}

impl ToolHandler for ArchivalSearchHandler {
    fn execute(&self, args: &Value, state: &mut AgentState) -> Result<ToolResult> {
        let query = args.get("query")
            .and_then(|v| v.as_str())
            .ok_or_else(|| LettaError::ToolExecution("Missing 'query' parameter".into()))?;
        
        let top_k = args.get("top_k")
            .and_then(|v| v.as_u64())
            .unwrap_or(5) as usize;
        
        // Simple text search for now (will be replaced with FTS5)
        let results: Vec<&Value> = state.archival_entries
            .iter()
            .filter(|entry| {
                entry.get("text")
                    .and_then(|t| t.as_str())
                    .map(|t| t.to_lowercase().contains(&query.to_lowercase()))
                    .unwrap_or(false)
            })
            .take(top_k)
            .collect();
        
        Ok(ToolResult::success(serde_json::json!({
            "results": results,
            "count": results.len()
        })).with_heartbeat())
    }
}

impl ToolHandler for ConversationSearchHandler {
    fn execute(&self, args: &Value, state: &mut AgentState) -> Result<ToolResult> {
        let query = args.get("query")
            .and_then(|v| v.as_str())
            .ok_or_else(|| LettaError::ToolExecution("Missing 'query' parameter".into()))?;
        
        let top_k = args.get("top_k")
            .and_then(|v| v.as_u64())
            .unwrap_or(5) as usize;
        
        let results = state.messages.search(query, top_k);
        
        Ok(ToolResult::success(serde_json::json!({
            "results": results,
            "count": results.len()
        })))
    }
}

#[derive(Clone)]
pub struct ToolExecutor {
    tools: HashMap<String, Box<dyn ToolHandler>>,
}

impl ToolExecutor {
    pub fn new() -> Self {
        let mut tools: HashMap<String, Box<dyn ToolHandler>> = HashMap::new();
        
        // Register built-in tools
        tools.insert("memory_replace".to_string(), Box::new(MemoryReplaceHandler));
        tools.insert("memory_append".to_string(), Box::new(MemoryAppendHandler));
        tools.insert("archival_insert".to_string(), Box::new(ArchivalInsertHandler));
        tools.insert("archival_search".to_string(), Box::new(ArchivalSearchHandler));
        tools.insert("conversation_search".to_string(), Box::new(ConversationSearchHandler));
        
        Self { tools }
    }
    
    pub fn register(&mut self, name: impl Into<String>, handler: Box<dyn ToolHandler>) {
        self.tools.insert(name.into(), handler);
    }
    
    pub fn execute(&self, call: &ToolCall, state: &mut AgentState) -> Result<ToolResult> {
        let handler = self.tools
            .get(&call.name)
            .ok_or_else(|| LettaError::ToolExecution(format!("Unknown tool: {}", call.name)))?;
        
        handler.execute(&call.arguments, state)
    }
    
    pub fn get_schemas(&self) -> Vec<ToolSchema> {
        // Return schemas for all registered tools
        vec![
            ToolSchema {
                name: "memory_replace".to_string(),
                description: "Replace the contents of a memory block".to_string(),
                parameters: serde_json::json!({
                    "type": "object",
                    "properties": {
                        "label": {"type": "string", "description": "Memory block label"},
                        "value": {"type": "string", "description": "New value"}
                    },
                    "required": ["label", "value"]
                }),
                required: vec!["label".to_string(), "value".to_string()],
            },
            ToolSchema {
                name: "memory_append".to_string(),
                description: "Append text to a memory block".to_string(),
                parameters: serde_json::json!({
                    "type": "object",
                    "properties": {
                        "label": {"type": "string", "description": "Memory block label"},
                        "text": {"type": "string", "description": "Text to append"}
                    },
                    "required": ["label", "text"]
                }),
                required: vec!["label".to_string(), "text".to_string()],
            },
            ToolSchema {
                name: "archival_insert".to_string(),
                description: "Insert text into archival memory".to_string(),
                parameters: serde_json::json!({
                    "type": "object",
                    "properties": {
                        "folder": {"type": "string", "description": "Folder name"},
                        "text": {"type": "string", "description": "Text to archive"}
                    },
                    "required": ["text"]
                }),
                required: vec!["text".to_string()],
            },
            ToolSchema {
                name: "archival_search".to_string(),
                description: "Search archival memory".to_string(),
                parameters: serde_json::json!({
                    "type": "object",
                    "properties": {
                        "query": {"type": "string", "description": "Search query"},
                        "top_k": {"type": "integer", "description": "Number of results"}
                    },
                    "required": ["query"]
                }),
                required: vec!["query".to_string()],
            },
            ToolSchema {
                name: "conversation_search".to_string(),
                description: "Search conversation history".to_string(),
                parameters: serde_json::json!({
                    "type": "object",
                    "properties": {
                        "query": {"type": "string", "description": "Search query"},
                        "top_k": {"type": "integer", "description": "Number of results"}
                    },
                    "required": ["query"]
                }),
                required: vec!["query".to_string()],
            },
        ]
    }
}