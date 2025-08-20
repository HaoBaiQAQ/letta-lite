pub mod agent;
pub mod memory;
pub mod message;
pub mod tool;
pub mod provider;
pub mod af;
pub mod error;
pub mod context;

pub use agent::{Agent, AgentConfig, AgentState};
pub use memory::{Memory, MemoryBlock, MemoryType};
pub use message::{Message, MessageRole};
pub use tool::{Tool, ToolCall, ToolResult, ToolExecutor};
pub use provider::{LlmProvider, Completion, CompletionRequest};
pub use af::{AgentFile, AgentFileV1};
pub use error::{LettaError, Result};
pub use context::ContextManager;

/// Library version
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Maximum context window size (tokens)
pub const DEFAULT_MAX_CONTEXT: usize = 8192;

/// Default message buffer size
pub const DEFAULT_MESSAGE_BUFFER: usize = 100;