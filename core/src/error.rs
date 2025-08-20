use thiserror::Error;

#[derive(Error, Debug)]
pub enum LettaError {
    #[error("Storage error: {0}")]
    Storage(#[from] letta_storage::StorageError),
    
    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),
    
    #[error("Provider error: {0}")]
    Provider(String),
    
    #[error("Tool execution error: {0}")]
    ToolExecution(String),
    
    #[error("Memory error: {0}")]
    Memory(String),
    
    #[error("Context overflow: current {current}, max {max}")]
    ContextOverflow { current: usize, max: usize },
    
    #[error("Agent not found: {0}")]
    AgentNotFound(String),
    
    #[error("Invalid configuration: {0}")]
    InvalidConfig(String),
    
    #[error("Sync error: {0}")]
    Sync(String),
    
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    
    #[error("Unknown error: {0}")]
    Unknown(String),
}

pub type Result<T> = std::result::Result<T, LettaError>;