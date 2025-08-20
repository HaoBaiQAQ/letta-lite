# Letta Lite Architecture

## Overview

Letta Lite is a portable, offline-first implementation of Letta agents designed for mobile and edge devices. It provides a lightweight (~2-3MB) runtime that can operate completely offline while maintaining compatibility with Letta's cloud infrastructure.

## Design Principles

1. **Minimal Footprint**: Core binary under 3MB for mobile deployment
2. **Offline-First**: Full functionality without network connectivity
3. **Cloud-Compatible**: Seamless sync with Letta cloud servers
4. **Cross-Platform**: Single codebase for iOS, Android, Web, and Desktop
5. **Memory-Safe**: Rust core prevents memory leaks and crashes
6. **Battery-Efficient**: Optimized for mobile battery life

## System Architecture

```
┌──────────────────────────────────────────────────┐
│                Application Layer                  │
│  (iOS App / Android App / React Native / CLI)    │
└──────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────┐
│              Language Bindings Layer              │
│   Swift │ Kotlin/JNI │ TypeScript │ Python       │
└──────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────┐
│                  C FFI Layer                      │
│            (letta_ffi - stable C ABI)            │
└──────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────┐
│                  Rust Core Layer                  │
├──────────────────────────────────────────────────┤
│  ┌─────────┐  ┌─────────┐  ┌──────────┐        │
│  │  Agent  │  │ Memory  │  │   Tools  │        │
│  │  Loop   │  │  Mgmt   │  │  Engine  │        │
│  └─────────┘  └─────────┘  └──────────┘        │
│  ┌─────────┐  ┌─────────┐  ┌──────────┐        │
│  │ Context │  │   AF    │  │   Sync   │        │
│  │  Mgmt   │  │ Format  │  │  Client  │        │
│  └─────────┘  └─────────┘  └──────────┘        │
└──────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────┐
│               Storage & Provider Layer            │
├──────────────────────────────────────────────────┤
│  ┌─────────┐  ┌─────────┐  ┌──────────┐        │
│  │ SQLite  │  │  LLM    │  │ Embedder │        │
│  │  + FTS5 │  │Provider │  │ Provider │        │
│  └─────────┘  └─────────┘  └──────────┘        │
└──────────────────────────────────────────────────┘
```

## Core Components

### 1. Agent Loop (`core/src/agent.rs`)

The agent loop implements the core conversational flow:

```rust
loop {
    // 1. Build context from memory + messages
    let prompt = context.build_prompt()?;
    
    // 2. Check context window limits
    if context.should_summarize() {
        summarize_older_messages();
    }
    
    // 3. Call LLM provider
    let completion = provider.complete(prompt).await?;
    
    // 4. Execute tool calls if any
    for tool_call in completion.tool_calls {
        let result = executor.execute(tool_call)?;
        if result.request_heartbeat {
            continue; // Loop again
        }
    }
    
    // 5. Return final response
    return completion.text;
}
```

### 2. Memory System (`core/src/memory.rs`)

Block-based memory system compatible with Letta:

- **Core Memory**: Always in context, editable blocks
- **Archival Memory**: Searchable long-term storage
- **Recall Memory**: Conversation history with search

Memory blocks support:
- Soft limits with automatic truncation
- Template-based rendering (Jinja2-style)
- Token counting for context management

### 3. Tool Execution (`core/src/tool.rs`)

Sandboxed tool execution with built-in tools:

- `memory_replace`: Update memory blocks
- `memory_append`: Append to memory blocks
- `archival_insert`: Add to long-term storage
- `archival_search`: FTS5-powered search
- `conversation_search`: Search message history

Tool execution flow:
1. Parse tool call from LLM response
2. Validate arguments against schema
3. Execute in sandboxed environment
4. Return result with optional heartbeat

### 4. Storage Layer (`storage/src/`)

SQLite-based storage with:

- **FTS5**: Full-text search for archival
- **Vector Storage**: Optional embeddings (sqlite-vec)
- **Sync Metadata**: Track local/cloud versions
- **Migrations**: Automated schema updates

### 5. Provider System (`core/src/provider.rs`)

Pluggable LLM providers:

- **Toy Provider**: Deterministic testing
- **Llama.cpp**: Local inference
- **OpenAI/Anthropic**: Cloud providers
- **Letta Cloud**: Direct integration

### 6. Agent File Format (`core/src/af.rs`)

Compatible with Letta's AF v0.1.0:

```json
{
  "version": "0.1.0",
  "agents": [...],
  "blocks": [...],
  "messages": [...],
  "tools": [...],
  "metadata": {...}
}
```

### 7. Sync Engine (`sync/src/`)

Cloud synchronization with:

- **Conflict Resolution**: Last-write-wins, cloud-wins, or merge
- **Delta Sync**: Only sync changes
- **Auto-sync**: Background synchronization
- **Offline Queue**: Queue changes when offline

## Data Flow

### Message Processing

```
User Input
    ↓
Message Queue
    ↓
Context Builder
    ├─→ Memory Blocks
    ├─→ Recent Messages
    └─→ Tool Schemas
    ↓
LLM Provider
    ↓
Response Parser
    ├─→ Tool Executor → Loop
    └─→ Final Response → User
```

### Sync Flow

```
Local Changes
    ↓
Sync Queue
    ↓
Conflict Detection
    ├─→ No Conflict → Apply
    └─→ Conflict → Resolution Strategy
    ↓
Cloud Update
    ↓
Local Update
```

## Mobile Optimizations

### Binary Size Reduction

1. **Profile-guided Optimization**: `--profile mobile`
2. **Link-time Optimization**: `lto = true`
3. **Symbol Stripping**: Remove debug symbols
4. **Single Codegen Unit**: Better optimization
5. **Panic Abort**: Smaller panic handler

### Memory Management

1. **Bounded Buffers**: Fixed-size message buffers
2. **Lazy Loading**: Load data on demand
3. **Memory Pools**: Reuse allocations
4. **Reference Counting**: Automatic cleanup

### Battery Efficiency

1. **Batch Operations**: Group database writes
2. **Lazy Sync**: Sync when charging/WiFi
3. **CPU Throttling**: Limit background work
4. **Wake Lock Management**: Minimize wake time

## Security Considerations

### Data Protection

1. **Encryption at Rest**: Optional SQLCipher
2. **Secure Key Storage**: Platform keychains
3. **Memory Scrubbing**: Clear sensitive data
4. **Secure Communication**: TLS for sync

### Input Validation

1. **Schema Validation**: Validate all inputs
2. **SQL Injection Prevention**: Prepared statements
3. **Command Injection Prevention**: No shell execution
4. **Path Traversal Prevention**: Validate file paths

## Performance Characteristics

### Benchmarks (iPhone 14 Pro)

| Operation | Time | Memory |
|-----------|------|--------|
| Agent Creation | 12ms | 1.2MB |
| Message Step | 35ms | 2.1MB |
| Archival Search (1000 items) | 8ms | 0.3MB |
| AF Export | 15ms | 0.5MB |
| Sync (100 messages) | 250ms | 1.8MB |

### Scalability Limits

- Messages: 10,000 per agent
- Archival Chunks: 100,000 per agent
- Memory Blocks: 100 per agent
- Concurrent Agents: 10
- Context Window: 8,192 tokens (configurable)

## Platform-Specific Considerations

### iOS

- **Swift Package Manager**: Native integration
- **XCFramework**: Universal binary
- **Background Modes**: Sync during background refresh
- **Core Data Integration**: Optional

### Android

- **AAR Package**: Easy integration
- **JNI Bridge**: Efficient native calls
- **WorkManager**: Background sync
- **Room Integration**: Optional

### React Native

- **TurboModules**: New architecture support
- **Hermes**: Optimized JS engine
- **JSI**: Direct native access
- **CodePush**: Hot updates

## Future Enhancements

### Planned Features

1. **Vector Search**: sqlite-vec integration
2. **Multi-Agent**: Agent communication
3. **Streaming**: Token-by-token responses
4. **Voice**: Speech-to-text/text-to-speech
5. **Vision**: Image understanding

### Experimental Features

1. **WebAssembly**: Browser deployment
2. **Edge Functions**: Cloudflare Workers
3. **P2P Sync**: Device-to-device sync
4. **Homomorphic Encryption**: Private cloud sync
5. **Differential Privacy**: Usage analytics

## Testing Strategy

### Unit Tests

- Core logic validation
- Memory operations
- Tool execution
- AF import/export

### Integration Tests

- End-to-end flows
- Storage persistence
- Sync operations
- Provider switching

### Platform Tests

- iOS Simulator tests
- Android Emulator tests
- React Native E2E tests
- Node.js CLI tests

### Performance Tests

- Load testing (1000+ messages)
- Memory leak detection
- Battery usage profiling
- Network efficiency

## Debugging

### Logging Levels

```rust
RUST_LOG=debug     # Verbose logging
RUST_LOG=info      # Standard logging
RUST_LOG=warn      # Warnings only
RUST_LOG=error     # Errors only
```

### Debug Tools

- **LLDB/GDB**: Native debugging
- **Instruments**: iOS profiling
- **Android Studio Profiler**: Android profiling
- **Chrome DevTools**: React Native debugging

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines.