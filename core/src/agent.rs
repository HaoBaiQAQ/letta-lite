use serde::{Deserialize, Serialize};
use uuid::Uuid;
use chrono::{DateTime, Utc};
use regex::Regex; // 用于匹配空/空格/中英文句号
use crate::{
    error::{LettaError, Result},
    memory::Memory,
    message::{Message, MessageBuffer, MessageRole, ToolCallInfo},
    tool::{ToolCall, ToolExecutor, ToolResult, ToolSchema},
    provider::{LlmProvider, CompletionRequest, TokenUsage},
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

    // ======================== 新增功能1：仅发送（添加消息到上下文，不触发AI回复）========================
    /// 仅将有效消息加入上下文，不触发AI回复（对应“仅发送”按钮）
    /// 过滤：空字符串、纯空格、仅中文句号「。」、仅英文点「.」、句号/点+空格
    pub fn send_only(&mut self, user_message: String) -> Result<()> {
        if Self::is_invalid_single_char_message(&user_message) {
            return Ok(()); // 过滤消息直接跳过
        }

        // 有效消息加入上下文
        let user_msg = Message::user(&user_message);
        self.state.messages.push(user_msg);
        self.state.updated_at = Utc::now();
        Ok(())
    }

    // ======================== 新增功能2：仅回复（基于现有上下文生成AI回复，无新消息）========================
    /// 基于当前上下文生成AI回复，不添加新消息（对应“仅回复”按钮，支持AI自言自语）
    pub async fn reply_only(&mut self) -> Result<StepResult> {
        let mut tool_trace = Vec::new();
        let mut iterations = 0;
        const MAX_ITERATIONS: usize = 10;
        
        loop {
            iterations += 1;
            if iterations > MAX_ITERATIONS {
                return Err(LettaError::ToolExecution("Maximum iterations exceeded".into()));
            }
            
            // Build prompt（复用原有逻辑）
            let prompt = self.context.build_prompt(
                &self.config.system_prompt,
                &self.state.memory,
                &self.state.messages.messages,
                self.config.max_messages,
            )?;
            
            // Check if we should summarize（复用原有逻辑）
            if self.context.should_summarize() {
                let summary = self.context.summarize_messages(&self.state.messages.messages, 10);
                self.state.messages.push(Message::system(format!("Context summary: {}", summary)));
            }
            
            // Get tool schemas if enabled（复用原有逻辑）
            let tools = if self.config.tools_enabled {
                self.tool_executor.get_schemas()
                    .into_iter()
                    .map(|s| serde_json::to_value(s).unwrap())
                    .collect()
            } else {
                vec![]
            };
            
            // Call LLM（复用原有逻辑）
            let request = CompletionRequest {
                prompt,
                tools,
                temperature: Some(self.config.temperature),
                max_tokens: None,
                stream: false,
            };
            
            let completion = self.provider.complete(request).await?;
            
            // Handle tool calls（复用原有逻辑）
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
                    continue;
                }
            }
            
            // Final response（复用原有逻辑，补充空回复兜底）
            let response_text = if !completion.text.is_empty() {
                completion.text
            } else {
                "I have no response to share.".to_string()
            };

            let assistant_msg = Message::assistant(&response_text);
            self.state.messages.push(assistant_msg);
            self.state.updated_at = Utc::now();
            
            return Ok(StepResult {
                text: response_text,
                tool_trace,
                usage: completion.usage,
            });
        }
    }
    
    // ======================== 微改旧功能：step方法（过滤指定单字符/无字符，触发自言自语）========================
    pub async fn step(&mut self, user_message: String) -> Result<StepResult> {
        let is_invalid = Self::is_invalid_single_char_message(&user_message);
        let is_valid_content = !is_invalid && !user_message.trim().is_empty();

        // 1. 仅有效消息加入上下文
        if is_valid_content {
            let user_msg = Message::user(&user_message);
            self.state.messages.push(user_msg);
            self.state.updated_at = Utc::now();
        }

        // 2. 所有情况（有效消息/过滤消息）都触发AI回复
        self.reply_only().await
    }

    // ======================== 核心修改：匹配空/空格/中文句号「。」/英文点「.」========================
    /// 匹配范围（严格符合“单字符和无字符”要求）：
    /// - 无字符：纯空字符串（^$）
    /// - 单字符：纯空格（^\s*$）、仅中文句号「。」（^。$）、仅英文点「.」（^\.$）
    /// - 兼容情况：句号/点+前后空格（已通过trimmed处理，不影响核心逻辑）
    fn is_invalid_single_char_message(msg: &str) -> bool {
        let trimmed = msg.trim();
        // 正则说明：仅匹配空、空格、中文句号、英文点，无任何易混淆字符，确保编译通过
        let re = Regex::new(r"^$|^\s*$|^。$|^\.$").unwrap();
        re.is_match(trimmed)
    }
    
    // ======================== 原有方法（保持不变）========================
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

    // ======================== 新增测试：验证空/空格/中英文句号过滤逻辑 ========================
    #[tokio::test]
    async fn test_invalid_single_char_message_trigger_self_talk() {
        let config = AgentConfig::default();
        let provider = Box::new(ToyProvider::new(ToyConfig { deterministic: true }));
        let mut agent = Agent::new(config, provider);
        let initial_msg_count = agent.state.messages.len();

        // 测试1：纯空消息 → 过滤，触发自言自语
        let result1 = agent.step("".to_string()).await.unwrap();
        assert!(!result1.text.is_empty());
        assert_eq!(agent.state.messages.len(), initial_msg_count + 1); // 仅新增AI回复

        // 测试2：纯空格 → 过滤，触发自言自语
        let result2 = agent.step("   ".to_string()).await.unwrap();
        assert!(!result2.text.is_empty());
        assert_eq!(agent.state.messages.len(), initial_msg_count + 2); // 仅新增AI回复

        // 测试3：中文句号「。」→ 过滤，触发自言自语
        let result3 = agent.step("。".to_string()).await.unwrap();
        assert!(!result3.text.is_empty());
        assert_eq!(agent.state.messages.len(), initial_msg_count + 3); // 仅新增AI回复

        // 测试4：英文点「.」→ 过滤，触发自言自语
        let result4 = agent.step(". ".to_string()).await.unwrap(); // 点+空格也过滤
        assert!(!result4.text.is_empty());
        assert_eq!(agent.state.messages.len(), initial_msg_count + 4); // 仅新增AI回复

        // 测试5：有效消息（含句号但非单字符）→ 加入上下文，触发回复
        let result5 = agent.step("你好。".to_string()).await.unwrap(); // 中文句号+文字（有效）
        let result6 = agent.step("test.".to_string()).await.unwrap(); // 英文点+文字（有效）
        assert!(!result5.text.is_empty() && !result6.text.is_empty());
        assert_eq!(agent.state.messages.len(), initial_msg_count + 8); // 新增2条用户消息+2条AI回复
    }

    // ======================== 新增测试：仅发送+仅回复功能 ========================
    #[tokio::test]
    async fn test_send_only_and_reply_only() {
        let config = AgentConfig::default();
        let provider = Box::new(ToyProvider::new(ToyConfig { deterministic: true }));
        let mut agent = Agent::new(config, provider);

        // 仅发送两条有效消息，不回复
        agent.send_only("第一条消息".to_string()).unwrap();
        agent.send_only("第二条消息。".to_string()).unwrap(); // 含中文句号（有效）
        assert_eq!(agent.state.messages.len(), 2); // 仅两条用户消息

        // 仅发送过滤消息，不加入上下文
        agent.send_only("".to_string()).unwrap();
        agent.send_only("   ".to_string()).unwrap();
        agent.send_only("。".to_string()).unwrap();
        agent.send_only(". ".to_string()).unwrap();
        assert_eq!(agent.state.messages.len(), 2); // 消息数不变

        // 仅回复，基于两条用户消息生成AI回复
        let result = agent.reply_only().await.unwrap();
        assert!(!result.text.is_empty());
        assert_eq!(agent.state.messages.len(), 3); // 新增AI回复消息
    }
}
