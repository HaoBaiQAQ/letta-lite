use serde::{Deserialize, Serialize};
use chrono::{DateTime, Utc};
use std::collections::HashMap;
use crate::{
    agent::{AgentConfig, AgentState},
    memory::{Memory, MemoryBlock},
    message::Message,
    tool::ToolSchema,
    error::Result,
};

/// Agent File format version 0.1.0 - compatible with Letta
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentFileV1 {
    pub version: String,
    pub agents: Vec<AgentExport>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub groups: Option<Vec<GroupExport>>,
    pub blocks: Vec<BlockExport>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub files: Option<Vec<FileExport>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sources: Option<Vec<SourceExport>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Vec<ToolExport>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mcp_servers: Option<Vec<McpServerExport>>,
    pub metadata: AgentFileMetadata,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentExport {
    pub id: String,
    pub name: String,
    pub system_prompt: String,
    pub message_buffer_size: usize,
    pub agent_state: AgentStateExport,
    pub messages: Vec<Message>,
    pub model: ModelConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentStateExport {
    pub user_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub tools: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_rules: Option<Vec<ToolRule>>,
    pub memory: MemoryExport,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryExport {
    pub memory_class: String,
    pub blocks: Vec<String>, // References to block IDs
    #[serde(skip_serializing_if = "Option::is_none")]
    pub template: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockExport {
    pub id: String,
    pub label: String,
    pub description: String,
    pub value: String,
    pub limit: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GroupExport {
    pub id: String,
    pub name: String,
    pub members: Vec<String>, // Agent IDs
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileExport {
    pub id: String,
    pub name: String,
    pub content: String,
    pub metadata: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceExport {
    pub id: String,
    pub name: String,
    pub source_type: String,
    pub metadata: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolExport {
    pub id: String,
    pub name: String,
    pub schema: ToolSchema,
    pub source_code: Option<String>,
    pub source_type: String, // "python", "builtin", "mcp"
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpServerExport {
    pub id: String,
    pub name: String,
    pub config: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolRule {
    pub tool_name: String,
    pub children: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelConfig {
    pub model_endpoint: String,
    pub context_window: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentFileMetadata {
    pub letta_version: String,
    pub export_time: DateTime<Utc>,
    pub export_source: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub additional: Option<HashMap<String, serde_json::Value>>,
}

pub struct AgentFile;

impl AgentFile {
    /// Export an agent to AF format
    pub fn export(
        config: &AgentConfig,
        state: &AgentState,
        tool_schemas: Vec<ToolSchema>,
    ) -> Result<AgentFileV1> {
        // Extract memory blocks
        let mut blocks = Vec::new();
        let mut block_ids = Vec::new();
        
        for (label, block) in state.memory.blocks() {
            let block_id = format!("block_{}", label);
            blocks.push(BlockExport {
                id: block_id.clone(),
                label: label.clone(),
                description: block.description.clone(),
                value: block.value.clone(),
                limit: block.limit,
            });
            block_ids.push(block_id);
        }
        
        // Create memory export
        let memory_export = MemoryExport {
            memory_class: match &state.memory.memory_type {
                crate::memory::MemoryType::Chat(_) => "ChatMemory".to_string(),
                crate::memory::MemoryType::Basic(_) => "BasicMemory".to_string(),
            },
            blocks: block_ids,
            template: None,
        };
        
        // Create agent state export
        let agent_state_export = AgentStateExport {
            user_id: None,
            created_at: state.created_at,
            updated_at: state.updated_at,
            tools: tool_schemas.iter().map(|s| s.name.clone()).collect(),
            tool_rules: None,
            memory: memory_export,
            metadata: Some(state.metadata.clone()),
        };
        
        // Create agent export
        let agent_export = AgentExport {
            id: state.id.clone(),
            name: state.name.clone(),
            system_prompt: config.system_prompt.clone(),
            message_buffer_size: config.max_messages,
            agent_state: agent_state_export,
            messages: state.messages.messages.clone(),
            model: ModelConfig {
                model_endpoint: config.model.clone(),
                context_window: config.max_context_tokens,
                temperature: Some(config.temperature),
                max_tokens: None,
            },
        };
        
        // Create tool exports
        let tools = Some(tool_schemas.into_iter().map(|schema| {
            ToolExport {
                id: format!("tool_{}", schema.name),
                name: schema.name.clone(),
                schema,
                source_code: None,
                source_type: "builtin".to_string(),
            }
        }).collect());
        
        Ok(AgentFileV1 {
            version: "0.1.0".to_string(),
            agents: vec![agent_export],
            groups: None,
            blocks,
            files: None,
            sources: None,
            tools,
            mcp_servers: None,
            metadata: AgentFileMetadata {
                letta_version: crate::VERSION.to_string(),
                export_time: Utc::now(),
                export_source: "letta-lite".to_string(),
                additional: None,
            },
        })
    }
    
    /// Import an agent from AF format
    pub fn import(af: &AgentFileV1) -> Result<(AgentConfig, AgentState)> {
        // Get the first agent (for now)
        let agent_export = af.agents.first()
            .ok_or_else(|| crate::error::LettaError::InvalidConfig("No agents in AF file".into()))?;
        
        // Create config
        let config = AgentConfig {
            name: agent_export.name.clone(),
            system_prompt: agent_export.system_prompt.clone(),
            model: agent_export.model.model_endpoint.clone(),
            max_messages: agent_export.message_buffer_size,
            max_context_tokens: agent_export.model.context_window,
            temperature: agent_export.model.temperature.unwrap_or(0.7),
            tools_enabled: !agent_export.agent_state.tools.is_empty(),
        };
        
        // Create state
        let mut state = AgentState::new(&agent_export.name);
        state.id = agent_export.id.clone();
        state.created_at = agent_export.agent_state.created_at;
        state.updated_at = agent_export.agent_state.updated_at;
        
        // Import memory blocks
        for block_id in &agent_export.agent_state.memory.blocks {
            if let Some(block_export) = af.blocks.iter().find(|b| &b.id == block_id) {
                state.memory.blocks_mut().insert(
                    block_export.label.clone(),
                    MemoryBlock {
                        label: block_export.label.clone(),
                        description: block_export.description.clone(),
                        value: block_export.value.clone(),
                        limit: block_export.limit,
                    },
                );
            }
        }
        
        // Import messages
        for msg in &agent_export.messages {
            state.messages.push(msg.clone());
        }
        
        // Import metadata
        if let Some(metadata) = &agent_export.agent_state.metadata {
            state.metadata = metadata.clone();
        }
        
        Ok((config, state))
    }
    
    /// Export to JSON string
    pub fn to_json(af: &AgentFileV1) -> Result<String> {
        serde_json::to_string_pretty(af)
            .map_err(|e| crate::error::LettaError::Serialization(e))
    }
    
    /// Import from JSON string
    pub fn from_json(json: &str) -> Result<AgentFileV1> {
        serde_json::from_str(json)
            .map_err(|e| crate::error::LettaError::Serialization(e))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_agent_file_export_import() {
        let config = AgentConfig::default();
        let mut state = AgentState::new("test-agent");
        state.memory.set_block("test", "test value").unwrap();
        
        // Export
        let af = AgentFile::export(&config, &state, vec![]).unwrap();
        assert_eq!(af.version, "0.1.0");
        assert_eq!(af.agents.len(), 1);
        
        // Convert to JSON and back
        let json = AgentFile::to_json(&af).unwrap();
        let af2 = AgentFile::from_json(&json).unwrap();
        
        // Import
        let (config2, state2) = AgentFile::import(&af2).unwrap();
        assert_eq!(config2.name, config.name);
        assert_eq!(state2.memory.get_block("test").unwrap().value, "test value");
    }
}