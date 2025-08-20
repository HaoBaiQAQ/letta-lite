use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use tera::{Context, Tera};
use crate::error::{LettaError, Result};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryBlock {
    pub label: String,
    pub description: String,
    pub value: String,
    #[serde(default = "default_limit")]
    pub limit: usize,
}

fn default_limit() -> usize {
    2000
}

impl MemoryBlock {
    pub fn new(label: impl Into<String>, description: impl Into<String>, value: impl Into<String>) -> Self {
        Self {
            label: label.into(),
            description: description.into(),
            value: value.into(),
            limit: default_limit(),
        }
    }
    
    pub fn with_limit(mut self, limit: usize) -> Self {
        self.limit = limit;
        self
    }
    
    pub fn replace(&mut self, new_value: impl Into<String>) -> Result<()> {
        let new = new_value.into();
        if new.len() > self.limit {
            return Err(LettaError::Memory(format!(
                "Value exceeds limit: {} > {}", new.len(), self.limit
            )));
        }
        self.value = new;
        Ok(())
    }
    
    pub fn append(&mut self, text: impl Into<String>) -> Result<()> {
        let text = text.into();
        let new_value = format!("{}\n{}", self.value, text);
        if new_value.len() > self.limit {
            // Truncate from the beginning to maintain recent context
            let start = new_value.len().saturating_sub(self.limit);
            self.value = new_value[start..].to_string();
        } else {
            self.value = new_value;
        }
        Ok(())
    }
    
    pub fn clear(&mut self) {
        self.value.clear();
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum MemoryType {
    #[serde(rename = "chat")]
    Chat(ChatMemory),
    #[serde(rename = "basic")]
    Basic(BasicMemory),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMemory {
    pub blocks: HashMap<String, MemoryBlock>,
    #[serde(skip)]
    template: Option<Tera>,
}

impl ChatMemory {
    pub fn new() -> Self {
        let mut blocks = HashMap::new();
        
        // Standard Letta memory blocks
        blocks.insert(
            "persona".to_string(),
            MemoryBlock::new(
                "persona",
                "Agent's personality and behavior",
                "I am a helpful AI assistant."
            )
        );
        
        blocks.insert(
            "human".to_string(),
            MemoryBlock::new(
                "human",
                "Information about the user",
                "User preferences and context will be stored here."
            )
        );
        
        Self {
            blocks,
            template: None,
        }
    }
    
    pub fn with_template(mut self, template_str: &str) -> Result<Self> {
        let mut tera = Tera::default();
        tera.add_raw_template("memory", template_str)
            .map_err(|e| LettaError::Memory(e.to_string()))?;
        self.template = Some(tera);
        Ok(self)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BasicMemory {
    pub blocks: HashMap<String, MemoryBlock>,
}

impl BasicMemory {
    pub fn new() -> Self {
        Self {
            blocks: HashMap::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Memory {
    #[serde(flatten)]
    pub memory_type: MemoryType,
}

impl Memory {
    pub fn new_chat() -> Self {
        Self {
            memory_type: MemoryType::Chat(ChatMemory::new()),
        }
    }
    
    pub fn new_basic() -> Self {
        Self {
            memory_type: MemoryType::Basic(BasicMemory::new()),
        }
    }
    
    pub fn blocks(&self) -> &HashMap<String, MemoryBlock> {
        match &self.memory_type {
            MemoryType::Chat(m) => &m.blocks,
            MemoryType::Basic(m) => &m.blocks,
        }
    }
    
    pub fn blocks_mut(&mut self) -> &mut HashMap<String, MemoryBlock> {
        match &mut self.memory_type {
            MemoryType::Chat(m) => &mut m.blocks,
            MemoryType::Basic(m) => &mut m.blocks,
        }
    }
    
    pub fn get_block(&self, label: &str) -> Option<&MemoryBlock> {
        self.blocks().get(label)
    }
    
    pub fn get_block_mut(&mut self, label: &str) -> Option<&mut MemoryBlock> {
        self.blocks_mut().get_mut(label)
    }
    
    pub fn set_block(&mut self, label: impl Into<String>, value: impl Into<String>) -> Result<()> {
        let label = label.into();
        if let Some(block) = self.get_block_mut(&label) {
            block.replace(value)?;
        } else {
            self.blocks_mut().insert(
                label.clone(),
                MemoryBlock::new(label, "User-defined block", value)
            );
        }
        Ok(())
    }
    
    pub fn append_block(&mut self, label: &str, text: impl Into<String>) -> Result<()> {
        if let Some(block) = self.get_block_mut(label) {
            block.append(text)?;
        } else {
            return Err(LettaError::Memory(format!("Block '{}' not found", label)));
        }
        Ok(())
    }
    
    pub fn render(&self) -> Result<String> {
        match &self.memory_type {
            MemoryType::Chat(chat_mem) => {
                if let Some(tera) = &chat_mem.template {
                    let mut context = Context::new();
                    for (label, block) in &chat_mem.blocks {
                        context.insert(label, &block.value);
                    }
                    tera.render("memory", &context)
                        .map_err(|e| LettaError::Memory(e.to_string()))
                } else {
                    // Default rendering
                    Ok(self.render_default())
                }
            }
            MemoryType::Basic(_) => Ok(self.render_default()),
        }
    }
    
    fn render_default(&self) -> String {
        let mut output = String::new();
        for (label, block) in self.blocks() {
            output.push_str(&format!("<{}_block>\n{}\n</{}_block>\n\n", label, block.value, label));
        }
        output
    }
    
    pub fn token_estimate(&self) -> usize {
        self.blocks()
            .values()
            .map(|b| b.value.len() / 4) // Rough estimate: 4 chars per token
            .sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_memory_block_operations() {
        let mut block = MemoryBlock::new("test", "Test block", "initial");
        
        // Test replace
        assert!(block.replace("new value").is_ok());
        assert_eq!(block.value, "new value");
        
        // Test append
        assert!(block.append("appended").is_ok());
        assert!(block.value.contains("new value"));
        assert!(block.value.contains("appended"));
        
        // Test limit
        let long_text = "x".repeat(3000);
        assert!(block.replace(&long_text).is_err());
    }
    
    #[test]
    fn test_chat_memory() {
        let mut memory = Memory::new_chat();
        
        // Check default blocks exist
        assert!(memory.get_block("persona").is_some());
        assert!(memory.get_block("human").is_some());
        
        // Test setting blocks
        assert!(memory.set_block("human", "User is Alice").is_ok());
        assert_eq!(memory.get_block("human").unwrap().value, "User is Alice");
        
        // Test custom blocks
        assert!(memory.set_block("custom", "Custom data").is_ok());
        assert!(memory.get_block("custom").is_some());
    }
}