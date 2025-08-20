use serde::{Deserialize, Serialize};
use uuid::Uuid;
use chrono::{DateTime, Utc};
use crate::{
    error::{LettaError, Result},
    memory::Memory,
    message::{Message, MessageBuffer, MessageRole, ToolCallInfo},
    tool::{ToolCall, ToolExecutor, ToolResult, ToolSchema},
    provider::{LlmProvider, CompletionRequest},
    context::ContextManager,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentConfig {
    pub name: String,
    pub system_prompt: String,
    pub model: String,
    pub max_messages: usize,
    pub max_context_tokens: usize,
    pub temperature: f32,
    pub tools_enabled: bool,
}

impl Default for AgentConfig {
    fn default() -> Self {
        Self {
            name: "assistant".to_string(),
            system_prompt: "You are a helpful AI assistant with persistent memory.".to_string(),
            model: "toy".to_string(),
            max_messages: 100,
            max_context_tokens: 8192,
            temperature: 0.7,
            tools_enabled: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentState {
    pub id: String,
    pub name: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub memory: Memory,
    pub messages: MessageBuffer,
    pub archival_entries: Vec<serde_json::Value>,
    pub metadata: serde_json::Value,
}

impl AgentState {
    pub fn new(name: impl Into<String>) -> Self {
        let now = Utc::now();
        Self {
            id: Uuid::new_v4().to_string(),
            name: name.into(),
            created_at: now,
            updated_at: now,
            memory: Memory::new_chat(),
            messages: MessageBuffer::new(100),
            archival_entries: Vec::new(),
            metadata: serde_json::json!({}),
        }
    }
}

pub struct Agent {
    pub config: AgentConfig,
    pub state: AgentState,
    context: ContextManager,
    tool_executor: ToolExecutor,
    provider: Box<dyn LlmProvider>,
}

impl Agent {
    pub fn new(config: AgentConfig, provider: Box<dyn LlmProvider>) -> Self {
        let state = AgentState::new(&config.name);
        let context = ContextManager::new(config.max_context_tokens);
        let tool_executor = ToolExecutor::new();
        
        Self {
            config,
            state,
            context,
            tool_executor,
            provider,
        }
    }
    
    pub fn with_state(mut self, state: AgentState) -> Self {
        self.state = state;
        self
    }
    
    pub async fn step(&mut self, user_message: String) -> Result<StepResult> {
        // Add user message
        let user_msg = Message::user(&user_message);
        self.state.messages.push(user_msg.clone());
        
        let mut tool_trace = Vec::new();
        let mut iterations = 0;
        const MAX_ITERATIONS: usize = 10;
        
        loop {
            iterations += 1;
            if iterations > MAX_ITERATIONS {
                return Err(LettaError::ToolExecution("Maximum iterations exceeded".into()));
            }
            
            // Build prompt
            let prompt = self.context.build_prompt(
                &self.config.system_prompt,
                &self.state.memory,
                &self.state.messages.messages,
                self.config.max_messages,
            )?;
            
            // Check if we should summarize
            if self.context.should_summarize() {
                let summary = self.context.summarize_messages(&self.state.messages.messages, 10);
                self.state.messages.push(Message::system(format!("Context summary: {}", summary)));
            }
            
            // Get tool schemas if enabled
            let tools = if self.config.tools_enabled {
                self.tool_executor.get_schemas()
                    .into_iter()
                    .map(|s| serde_json::to_value(s).unwrap())
                    .collect()
            } else {
                vec![]
            };
            
            // Call LLM
            let request = CompletionRequest {
                prompt,
                tools,
                temperature: Some(self.config.temperature),
                max_tokens: None,
                stream: false,
            };
            
            let completion = self.provider.complete(request).await?;
            
            // Handle tool calls
            if !completion.tool_calls.is_empty() {
                let mut request_heartbeat = false;
                
                for tool_call in &completion.tool_calls {
                    let result = self.tool_executor.execute(tool_call, &mut self.state)?;
                    
                    // Add tool result as message
                    let tool_msg = Message::tool(
                        tool_call.id.clone(),
                        serde_json::to_string(&result.result)?,
                    );
                    self.state.messages.push(tool_msg);
                    
                    tool_trace.push(serde_json::json!({
                        "tool": tool_call.name,
                        "args": tool_call.arguments,
                        "result": result.result,
                    }));
                    
                    if result.request_heartbeat {
                        request_heartbeat = true;
                    }
                }
                
                // Add assistant message with tool calls
                let assistant_msg = Message::assistant("")
                    .with_tool_calls(completion.tool_calls.iter().map(|tc| ToolCallInfo {
                        id: tc.id.clone(),
                        name: tc.name.clone(),
                        arguments: tc.arguments.clone(),
                    }).collect());
                self.state.messages.push(assistant_msg);
                
                if request_heartbeat || completion.request_heartbeat {
                    continue; // Run another iteration
                }
            }
            
            // Final response
            if !completion.text.is_empty() {
                let assistant_msg = Message::assistant(&completion.text);
                self.state.messages.push(assistant_msg);
                
                self.state.updated_at = Utc::now();
                
                return Ok(StepResult {
                    text: completion.text,
                    tool_trace,
                    usage: completion.usage,
                });
            }
        }
    }
    
    pub fn set_memory_block(&mut self, label: &str, value: &str) -> Result<()> {
        self.state.memory.set_block(label, value)?;
        self.state.updated_at = Utc::now();
        Ok(())
    }
    
    pub fn get_memory_block(&self, label: &str) -> Option<String> {
        self.state.memory.get_block(label).map(|b| b.value.clone())
    }
    
    pub fn add_archival(&mut self, folder: &str, text: &str) {
        self.state.archival_entries.push(serde_json::json!({
            "folder": folder,
            "text": text,
            "timestamp": Utc::now(),
        }));
        self.state.updated_at = Utc::now();
    }
    
    pub fn search_archival(&self, query: &str, top_k: usize) -> Vec<serde_json::Value> {
        self.state.archival_entries
            .iter()
            .filter(|entry| {
                entry.get("text")
                    .and_then(|t| t.as_str())
                    .map(|t| t.to_lowercase().contains(&query.to_lowercase()))
                    .unwrap_or(false)
            })
            .take(top_k)
            .cloned()
            .collect()
    }
    
    pub fn search_conversation(&self, query: &str, top_k: usize) -> Vec<Message> {
        self.state.messages.search(query, top_k)
            .into_iter()
            .cloned()
            .collect()
    }
    
    pub fn clear_messages(&mut self) {
        self.state.messages.clear();
        self.state.updated_at = Utc::now();
    }
    
    pub fn export_state(&self) -> Result<String> {
        serde_json::to_string_pretty(&self.state)
            .map_err(|e| LettaError::Serialization(e))
    }
    
    pub fn import_state(&mut self, json: &str) -> Result<()> {
        let state: AgentState = serde_json::from_str(json)?;
        self.state = state;
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StepResult {
    pub text: String,
    pub tool_trace: Vec<serde_json::Value>,
    pub usage: crate::provider::TokenUsage,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::{ToyProvider, ToyConfig};
    
    #[tokio::test]
    async fn test_agent_creation() {
        let config = AgentConfig::default();
        let provider = Box::new(ToyProvider::new(ToyConfig { deterministic: true }));
        let agent = Agent::new(config, provider);
        
        assert_eq!(agent.state.name, "assistant");
        assert!(agent.state.memory.get_block("persona").is_some());
    }
    
    #[tokio::test]
    async fn test_agent_step() {
        let config = AgentConfig::default();
        let provider = Box::new(ToyProvider::new(ToyConfig { deterministic: true }));
        let mut agent = Agent::new(config, provider);
        
        let result = agent.step("Hello!".to_string()).await.unwrap();
        assert!(!result.text.is_empty());
    }
    
    #[tokio::test]
    async fn test_memory_operations() {
        let config = AgentConfig::default();
        let provider = Box::new(ToyProvider::new(ToyConfig { deterministic: true }));
        let mut agent = Agent::new(config, provider);
        
        agent.set_memory_block("test", "test value").unwrap();
        assert_eq!(agent.get_memory_block("test"), Some("test value".to_string()));
    }
}