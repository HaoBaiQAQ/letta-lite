use letta_core::{
    Agent, AgentConfig,
    provider::{ProviderFactory, ProviderConfig, ToyConfig},
    af::AgentFile,
};
use letta_storage::{Storage, StorageConfig};
use letta_sync::{SyncClient, SyncConfig};
use std::path::PathBuf;
use tempfile::TempDir;

#[tokio::test]
async fn test_agent_lifecycle() {
    // Create temp directory for storage
    let temp_dir = TempDir::new().unwrap();
    let storage_path = temp_dir.path().join("test.db");
    
    // Initialize storage
    let storage = Storage::new(StorageConfig {
        path: storage_path,
        max_connections: 1,
    }).unwrap();
    
    // Create provider
    let provider = ProviderFactory::create(
        ProviderConfig::Toy(ToyConfig { deterministic: true })
    ).await.unwrap();
    
    // Create agent
    let config = AgentConfig {
        name: "test-agent".to_string(),
        system_prompt: "You are a test agent.".to_string(),
        model: "toy".to_string(),
        ..Default::default()
    };
    
    let mut agent = Agent::new(config.clone(), provider);
    
    // Test memory operations
    agent.set_memory_block("test", "test value").unwrap();
    assert_eq!(agent.get_memory_block("test"), Some("test value".to_string()));
    
    // Test archival
    agent.add_archival("test-folder", "test content");
    let results = agent.search_archival("test", 10);
    assert!(!results.is_empty());
    
    // Test conversation
    let response = agent.step("Hello!".to_string()).await.unwrap();
    assert!(!response.text.is_empty());
    
    // Test export/import
    let af = AgentFile::export(&config, &agent.state, vec![]).unwrap();
    assert_eq!(af.version, "0.1.0");
    
    let (config2, state2) = AgentFile::import(&af).unwrap();
    assert_eq!(config2.name, config.name);
    assert_eq!(state2.memory.get_block("test").unwrap().value, "test value");
}

#[tokio::test]
async fn test_tool_execution() {
    let provider = ProviderFactory::create(
        ProviderConfig::Toy(ToyConfig { deterministic: false })
    ).await.unwrap();
    
    let config = AgentConfig::default();
    let mut agent = Agent::new(config, provider);
    
    // Test with tool-triggering prompt
    let response = agent.step("Search for latest readings #DO_SEARCH".to_string()).await.unwrap();
    assert!(!response.tool_trace.is_empty());
    
    // Verify tool was called
    let tool_trace = &response.tool_trace[0];
    assert_eq!(tool_trace["tool"], "archival_search");
}

#[tokio::test]
async fn test_memory_limits() {
    let provider = ProviderFactory::create(
        ProviderConfig::Toy(ToyConfig { deterministic: true })
    ).await.unwrap();
    
    let config = AgentConfig::default();
    let mut agent = Agent::new(config, provider);
    
    // Test memory block limits
    let long_text = "x".repeat(3000);
    let result = agent.set_memory_block("test", &long_text);
    assert!(result.is_err()); // Should fail due to limit
    
    // Test within limit
    let short_text = "x".repeat(1000);
    let result = agent.set_memory_block("test", &short_text);
    assert!(result.is_ok());
}

#[tokio::test]
async fn test_context_overflow() {
    let provider = ProviderFactory::create(
        ProviderConfig::Toy(ToyConfig { deterministic: true })
    ).await.unwrap();
    
    let mut config = AgentConfig::default();
    config.max_context_tokens = 100; // Very small context
    
    let mut agent = Agent::new(config, provider);
    
    // Add many messages to trigger overflow handling
    for i in 0..20 {
        let response = agent.step(format!("Message {}", i)).await;
        assert!(response.is_ok());
    }
    
    // Should still work with summarization
    let response = agent.step("Final message".to_string()).await.unwrap();
    assert!(!response.text.is_empty());
}

#[tokio::test]
async fn test_storage_persistence() {
    let temp_dir = TempDir::new().unwrap();
    let storage_path = temp_dir.path().join("persist.db");
    
    // Create and populate storage
    {
        let storage = Storage::new(StorageConfig {
            path: storage_path.clone(),
            max_connections: 1,
        }).unwrap();
        
        let agent = letta_storage::StoredAgent::new("test", "prompt");
        storage.create_agent(&agent).unwrap();
        
        let block = letta_storage::StoredBlock::new(&agent.id, "test", "value");
        storage.upsert_block(&block).unwrap();
    }
    
    // Reopen and verify
    {
        let storage = Storage::new(StorageConfig {
            path: storage_path,
            max_connections: 1,
        }).unwrap();
        
        let agents = storage.list_agents().unwrap();
        assert_eq!(agents.len(), 1);
        assert_eq!(agents[0].name, "test");
        
        let blocks = storage.get_blocks(&agents[0].id).unwrap();
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].value, "value");
    }
}

#[tokio::test]
async fn test_fts_search() {
    let storage = Storage::memory().unwrap();
    
    let agent = letta_storage::StoredAgent::new("test", "prompt");
    storage.create_agent(&agent).unwrap();
    
    // Add chunks with different content
    let chunk1 = letta_storage::StoredChunk::new(&agent.id, "docs", "The quick brown fox jumps");
    let chunk2 = letta_storage::StoredChunk::new(&agent.id, "docs", "over the lazy dog");
    let chunk3 = letta_storage::StoredChunk::new(&agent.id, "docs", "The fox is clever");
    
    storage.add_chunk(&chunk1).unwrap();
    storage.add_chunk(&chunk2).unwrap();
    storage.add_chunk(&chunk3).unwrap();
    
    // Search for "fox"
    let results = storage.search_chunks_fts(&agent.id, "fox", 10).unwrap();
    assert_eq!(results.len(), 2);
    
    // Search for "lazy"
    let results = storage.search_chunks_fts(&agent.id, "lazy", 10).unwrap();
    assert_eq!(results.len(), 1);
    assert!(results[0].text.contains("lazy"));
}

#[tokio::test]
async fn test_message_search() {
    let storage = Storage::memory().unwrap();
    
    let agent = letta_storage::StoredAgent::new("test", "prompt");
    storage.create_agent(&agent).unwrap();
    
    // Add messages
    let msg1 = letta_storage::StoredMessage::new(&agent.id, "user", "Hello world");
    let msg2 = letta_storage::StoredMessage::new(&agent.id, "assistant", "Hi there");
    let msg3 = letta_storage::StoredMessage::new(&agent.id, "user", "How are you?");
    
    storage.add_message(&msg1).unwrap();
    storage.add_message(&msg2).unwrap();
    storage.add_message(&msg3).unwrap();
    
    // Search messages
    let results = storage.search_messages(&agent.id, "Hello", 10).unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].content, "Hello world");
}

#[tokio::test]
async fn test_af_compatibility() {
    // Test that our AF format is compatible with Letta's
    let provider = ProviderFactory::create(
        ProviderConfig::Toy(ToyConfig { deterministic: true })
    ).await.unwrap();
    
    let config = AgentConfig::default();
    let mut agent = Agent::new(config.clone(), provider);
    
    // Set up agent state
    agent.set_memory_block("persona", "I am a helpful assistant").unwrap();
    agent.set_memory_block("human", "The user prefers concise answers").unwrap();
    agent.add_archival("knowledge", "Important fact 1");
    agent.add_archival("knowledge", "Important fact 2");
    
    let _ = agent.step("Hello".to_string()).await.unwrap();
    let _ = agent.step("How are you?".to_string()).await.unwrap();
    
    // Export to AF
    let af = AgentFile::export(&config, &agent.state, vec![]).unwrap();
    
    // Verify AF structure
    assert_eq!(af.version, "0.1.0");
    assert_eq!(af.agents.len(), 1);
    assert!(af.blocks.len() >= 2); // At least persona and human
    assert_eq!(af.agents[0].messages.len(), 4); // 2 user + 2 assistant
    
    // Verify metadata
    assert_eq!(af.metadata.export_source, "letta-lite");
    
    // Test round-trip
    let json = AgentFile::to_json(&af).unwrap();
    let af2 = AgentFile::from_json(&json).unwrap();
    assert_eq!(af.version, af2.version);
    assert_eq!(af.agents.len(), af2.agents.len());
}

#[cfg(feature = "sync")]
#[tokio::test]
async fn test_sync_conflict_resolution() {
    use letta_sync::{ConflictInfo};
    
    let sync_config = SyncConfig {
        endpoint: "http://localhost:8000".to_string(),
        api_key: "test".to_string(),
        sync_interval: 0,
        conflict_resolution: "last-write-wins".to_string(),
        auto_sync: false,
    };
    
    let client = SyncClient::new(sync_config).unwrap();
    
    // Test conflict resolution strategies
    let conflict = ConflictInfo {
        field: "test_field".to_string(),
        local_value: serde_json::json!({"a": 1, "b": 2}),
        cloud_value: serde_json::json!({"a": 3, "c": 4}),
        resolution: String::new(),
    };
    
    // Last-write-wins should pick local
    let resolved = client.resolve_conflict(&conflict);
    assert_eq!(resolved["a"], 1);
    assert_eq!(resolved["b"], 2);
}

// Benchmark tests
#[cfg(feature = "bench")]
mod bench {
    use super::*;
    use criterion::{black_box, Criterion};
    
    pub fn bench_agent_step(c: &mut Criterion) {
        let rt = tokio::runtime::Runtime::new().unwrap();
        
        c.bench_function("agent_step", |b| {
            b.iter(|| {
                rt.block_on(async {
                    let provider = ProviderFactory::create(
                        ProviderConfig::Toy(ToyConfig { deterministic: true })
                    ).await.unwrap();
                    
                    let config = AgentConfig::default();
                    let mut agent = Agent::new(config, provider);
                    
                    let response = agent.step(black_box("Hello".to_string())).await.unwrap();
                    black_box(response);
                });
            });
        });
    }
    
    pub fn bench_archival_search(c: &mut Criterion) {
        let storage = Storage::memory().unwrap();
        let agent = letta_storage::StoredAgent::new("test", "prompt");
        storage.create_agent(&agent).unwrap();
        
        // Add many chunks
        for i in 0..1000 {
            let chunk = letta_storage::StoredChunk::new(
                &agent.id,
                "docs",
                &format!("Document content {}", i)
            );
            storage.add_chunk(&chunk).unwrap();
        }
        
        c.bench_function("archival_search", |b| {
            b.iter(|| {
                let results = storage.search_chunks_fts(
                    &agent.id,
                    black_box("content"),
                    black_box(10)
                ).unwrap();
                black_box(results);
            });
        });
    }
}