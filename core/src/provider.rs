use serde::{Deserialize, Serialize};
use async_trait::async_trait;
use crate::error::Result;
use crate::tool::ToolCall;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompletionRequest {
    pub prompt: String,
    pub tools: Vec<serde_json::Value>,
    pub temperature: Option<f32>,
    pub max_tokens: Option<usize>,
    pub stream: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Completion {
    pub text: String,
    pub tool_calls: Vec<ToolCall>,
    pub request_heartbeat: bool,
    pub usage: TokenUsage,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenUsage {
    pub prompt_tokens: usize,
    pub completion_tokens: usize,
    pub total_tokens: usize,
}

impl Completion {
    pub fn text(content: impl Into<String>) -> Self {
        let text = content.into();
        let tokens = text.len() / 4; // Rough estimate
        Self {
            text,
            tool_calls: vec![],
            request_heartbeat: false,
            usage: TokenUsage {
                prompt_tokens: 0,
                completion_tokens: tokens,
                total_tokens: tokens,
            },
        }
    }
    
    pub fn with_tools(mut self, calls: Vec<ToolCall>) -> Self {
        self.tool_calls = calls;
        self
    }
    
    pub fn with_heartbeat(mut self) -> Self {
        self.request_heartbeat = true;
        self
    }
}

#[async_trait]
pub trait LlmProvider: Send + Sync {
    async fn complete(&self, request: CompletionRequest) -> Result<Completion>;
    
    async fn embed(&self, texts: Vec<String>) -> Result<Vec<Vec<f32>>> {
        // Default implementation returns empty embeddings
        Ok(texts.iter().map(|_| vec![0.0; 768]).collect())
    }
    
    fn name(&self) -> &str;
    
    fn max_tokens(&self) -> usize {
        8192
    }
}

// Provider configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ProviderConfig {
    #[serde(rename = "toy")]
    Toy(ToyConfig),
    #[serde(rename = "openai")]
    OpenAI(OpenAIConfig),
    #[serde(rename = "anthropic")]
    Anthropic(AnthropicConfig),
    #[serde(rename = "llama")]
    Llama(LlamaConfig),
    #[serde(rename = "letta")]
    LettaCloud(LettaCloudConfig),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToyConfig {
    pub deterministic: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenAIConfig {
    pub api_key: String,
    pub model: String,
    pub base_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AnthropicConfig {
    pub api_key: String,
    pub model: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LlamaConfig {
    pub model_path: String,
    pub context_size: usize,
    pub n_threads: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LettaCloudConfig {
    pub endpoint: String,
    pub api_key: String,
    pub model: String,
}

// Provider factory
pub struct ProviderFactory;

impl ProviderFactory {
    pub async fn create(config: ProviderConfig) -> Result<Box<dyn LlmProvider>> {
        match config {
            ProviderConfig::Toy(cfg) => {
                Ok(Box::new(ToyProvider::new(cfg)))
            }
            ProviderConfig::OpenAI(_cfg) => {
                // TODO: Implement OpenAI provider
                Err(crate::error::LettaError::Provider("OpenAI provider not yet implemented".into()))
            }
            ProviderConfig::Anthropic(_cfg) => {
                // TODO: Implement Anthropic provider
                Err(crate::error::LettaError::Provider("Anthropic provider not yet implemented".into()))
            }
            ProviderConfig::Llama(_cfg) => {
                // TODO: Implement Llama provider
                Err(crate::error::LettaError::Provider("Llama provider not yet implemented".into()))
            }
            ProviderConfig::LettaCloud(_cfg) => {
                // TODO: Implement Letta Cloud provider
                Err(crate::error::LettaError::Provider("Letta Cloud provider not yet implemented".into()))
            }
        }
    }
}

// Toy provider for testing
pub struct ToyProvider {
    config: ToyConfig,
}

impl ToyProvider {
    pub fn new(config: ToyConfig) -> Self {
        Self { config }
    }
}

#[async_trait]
impl LlmProvider for ToyProvider {
    async fn complete(&self, request: CompletionRequest) -> Result<Completion> {
        // Deterministic responses for testing
        if request.prompt.contains("#DO_SEARCH") {
            // Trigger archival search
            Ok(Completion {
                text: String::new(),
                tool_calls: vec![ToolCall {
                    id: "call_1".to_string(),
                    name: "archival_search".to_string(),
                    arguments: serde_json::json!({
                        "query": "latest readings",
                        "top_k": 3
                    }),
                }],
                request_heartbeat: true,
                usage: TokenUsage {
                    prompt_tokens: request.prompt.len() / 4,
                    completion_tokens: 10,
                    total_tokens: request.prompt.len() / 4 + 10,
                },
            })
        } else if request.prompt.contains("#MEMORY_UPDATE") {
            // Update memory
            Ok(Completion {
                text: String::new(),
                tool_calls: vec![ToolCall {
                    id: "call_2".to_string(),
                    name: "memory_replace".to_string(),
                    arguments: serde_json::json!({
                        "label": "human",
                        "value": "Updated user information"
                    }),
                }],
                request_heartbeat: false,
                usage: TokenUsage {
                    prompt_tokens: request.prompt.len() / 4,
                    completion_tokens: 10,
                    total_tokens: request.prompt.len() / 4 + 10,
                },
            })
        } else if request.prompt.contains("Tool [") {
            // Response after tool execution
            Ok(Completion::text("Based on the search results, here's a summary of the latest readings: The most recent values show stable patterns with readings at 168 mg/dL and 112 mg/dL."))
        } else {
            // Default response
            Ok(Completion::text(if self.config.deterministic {
                "I understand your request. How can I help you further?"
            } else {
                "This is a test response from the toy provider."
            }))
        }
    }
    
    fn name(&self) -> &str {
        "toy"
    }
}