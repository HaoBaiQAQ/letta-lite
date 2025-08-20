use async_trait::async_trait;
use letta_core::{
    provider::{LlmProvider, CompletionRequest, Completion, TokenUsage},
    tool::ToolCall,
    error::Result,
};
use serde_json::json;

pub struct ToyProvider {
    deterministic: bool,
    call_count: std::sync::atomic::AtomicUsize,
}

impl ToyProvider {
    pub fn new(deterministic: bool) -> Self {
        Self {
            deterministic,
            call_count: std::sync::atomic::AtomicUsize::new(0),
        }
    }
}

#[async_trait]
impl LlmProvider for ToyProvider {
    async fn complete(&self, request: CompletionRequest) -> Result<Completion> {
        let count = self.call_count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        
        // Simulate different behaviors based on prompt content
        if request.prompt.contains("#DO_SEARCH") {
            // Trigger archival search
            Ok(Completion {
                text: String::new(),
                tool_calls: vec![ToolCall {
                    id: format!("call_{}", count),
                    name: "archival_search".to_string(),
                    arguments: json!({
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
                    id: format!("call_{}", count),
                    name: "memory_replace".to_string(),
                    arguments: json!({
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
            Ok(Completion::text(
                "Based on the search results, here's a summary of the latest readings: \
                The most recent values show stable patterns with readings at 168 mg/dL and 112 mg/dL."
            ))
        } else if self.deterministic {
            // Deterministic response for testing
            Ok(Completion::text(
                "I understand your request. How can I help you further?"
            ))
        } else {
            // Variable responses
            let responses = [
                "I'm here to help. What would you like to know?",
                "Thank you for your message. Let me assist you with that.",
                "I've processed your request. Is there anything specific you'd like me to focus on?",
                "That's an interesting point. Could you provide more details?",
                "I understand. Let me think about the best way to help you.",
            ];
            
            let response = responses[count % responses.len()];
            Ok(Completion::text(response))
        }
    }
    
    async fn embed(&self, texts: Vec<String>) -> Result<Vec<Vec<f32>>> {
        // Return mock embeddings (768-dimensional)
        Ok(texts.iter().map(|text| {
            let hash = text.bytes().fold(0u32, |acc, b| acc.wrapping_add(b as u32));
            let base = (hash as f32) / u32::MAX as f32;
            
            (0..768).map(|i| {
                ((base + i as f32 / 768.0) * 2.0 - 1.0).sin()
            }).collect()
        }).collect())
    }
    
    fn name(&self) -> &str {
        "toy"
    }
    
    fn max_tokens(&self) -> usize {
        8192
    }
}