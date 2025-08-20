use serde::{Deserialize, Serialize};
use crate::error::{LettaError, Result};
use crate::message::Message;
use crate::memory::Memory;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContextWindow {
    pub max_tokens: usize,
    pub current_tokens: usize,
    pub summarization_threshold: f32,
}

impl Default for ContextWindow {
    fn default() -> Self {
        Self {
            max_tokens: 8192,
            current_tokens: 0,
            summarization_threshold: 0.8,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ContextManager {
    window: ContextWindow,
}

impl ContextManager {
    pub fn new(max_tokens: usize) -> Self {
        Self {
            window: ContextWindow {
                max_tokens,
                current_tokens: 0,
                summarization_threshold: 0.8,
            },
        }
    }
    
    pub fn with_threshold(mut self, threshold: f32) -> Self {
        self.window.summarization_threshold = threshold;
        self
    }
    
    pub fn should_summarize(&self) -> bool {
        let usage_ratio = self.window.current_tokens as f32 / self.window.max_tokens as f32;
        usage_ratio >= self.window.summarization_threshold
    }
    
    pub fn update_usage(&mut self, tokens: usize) {
        self.window.current_tokens = tokens;
    }
    
    pub fn check_overflow(&self, additional_tokens: usize) -> Result<()> {
        let total = self.window.current_tokens + additional_tokens;
        if total > self.window.max_tokens {
            Err(LettaError::ContextOverflow {
                current: total,
                max: self.window.max_tokens,
            })
        } else {
            Ok(())
        }
    }
    
    pub fn build_prompt(
        &mut self,
        system_prompt: &str,
        memory: &Memory,
        messages: &[Message],
        max_messages: usize,
    ) -> Result<String> {
        let mut prompt_parts = vec![];
        let mut token_count = 0;
        
        // Add system prompt
        prompt_parts.push(format!("System: {}", system_prompt));
        token_count += system_prompt.len() / 4;
        
        // Add memory blocks
        let memory_str = memory.render()?;
        prompt_parts.push(format!("\n<memory>\n{}</memory>", memory_str));
        token_count += memory.token_estimate();
        
        // Add messages (most recent first, then reverse)
        let message_count = messages.len().min(max_messages);
        let start_idx = messages.len().saturating_sub(message_count);
        
        prompt_parts.push("\n<conversation>".to_string());
        for msg in &messages[start_idx..] {
            let msg_str = match msg.role {
                crate::message::MessageRole::System => format!("System: {}", msg.content),
                crate::message::MessageRole::User => format!("User: {}", msg.content),
                crate::message::MessageRole::Assistant => format!("Assistant: {}", msg.content),
                crate::message::MessageRole::Tool => {
                    format!("Tool [{}]: {}", msg.tool_call_id.as_ref().unwrap_or(&"unknown".to_string()), msg.content)
                }
            };
            prompt_parts.push(msg_str);
            token_count += msg.token_estimate();
        }
        prompt_parts.push("</conversation>".to_string());
        
        self.update_usage(token_count);
        
        // Check if we're within limits
        self.check_overflow(0)?;
        
        Ok(prompt_parts.join("\n"))
    }
    
    pub fn summarize_messages(&self, messages: &[Message], keep_recent: usize) -> String {
        // Simple summarization: keep system messages and recent messages
        let mut summary = String::from("Previous conversation summary:\n");
        
        let older_messages = &messages[..messages.len().saturating_sub(keep_recent)];
        
        // Group by topic/time
        for msg in older_messages.iter().filter(|m| matches!(m.role, crate::message::MessageRole::User | crate::message::MessageRole::Assistant)) {
            if msg.content.len() > 100 {
                // Truncate long messages
                summary.push_str(&format!("- {}: {}...\n", 
                    match msg.role {
                        crate::message::MessageRole::User => "User",
                        crate::message::MessageRole::Assistant => "Assistant",
                        _ => "Other",
                    },
                    &msg.content[..100]
                ));
            } else {
                summary.push_str(&format!("- {}: {}\n",
                    match msg.role {
                        crate::message::MessageRole::User => "User",
                        crate::message::MessageRole::Assistant => "Assistant",
                        _ => "Other",
                    },
                    msg.content
                ));
            }
        }
        
        summary
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_context_overflow() {
        let mut ctx = ContextManager::new(1000);
        ctx.update_usage(800);
        
        assert!(ctx.check_overflow(100).is_ok());
        assert!(ctx.check_overflow(300).is_err());
    }
    
    #[test]
    fn test_summarization_trigger() {
        let mut ctx = ContextManager::new(1000).with_threshold(0.8);
        
        ctx.update_usage(700);
        assert!(!ctx.should_summarize());
        
        ctx.update_usage(850);
        assert!(ctx.should_summarize());
    }
}