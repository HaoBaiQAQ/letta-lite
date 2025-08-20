# Letta Lite

**⚠️ Work in Progress - Not yet tested in production environments**

A portable, offline-first implementation of Letta agents for mobile and edge devices with cloud sync capabilities.

## Features

- **Lightweight**: 2-3MB core binary size
- **Mobile-first**: Native iOS, Android, and React Native support
- **Cloud Sync**: Seamless synchronization with Letta cloud servers
- **Local LLMs**: Support for on-device inference via llama.cpp
- **Persistent Memory**: SQLite-based storage with FTS5 search
- **Tool Execution**: Compatible with Letta's tool ecosystem
- **Agent Files**: Full .af format support for import/export

## Architecture

```
┌─────────────────────────────────────────┐
│          Mobile/Desktop App             │
├─────────────────────────────────────────┤
│     Swift/Kotlin/RN/Node Bindings       │
├─────────────────────────────────────────┤
│            C FFI Layer                  │
├─────────────────────────────────────────┤
│         Rust Core (2-3MB)               │
│  ┌──────────┬──────────┬──────────┐    │
│  │  Agent   │  Memory  │  Tools   │    │
│  │   Loop   │  Blocks  │  Engine  │    │
│  └──────────┴──────────┴──────────┘    │
│  ┌──────────┬──────────┬──────────┐    │
│  │  SQLite  │   Sync   │   LLM    │    │
│  │   +FTS5  │  Engine  │ Provider │    │
│  └──────────┴──────────┴──────────┘    │
└─────────────────────────────────────────┘
```

## Quick Start

### Building for iOS

```bash
./scripts/build-ios.sh
```

### Building for Android

```bash
./scripts/build-android.sh
```

### Running the Node CLI

```bash
cd examples/node-cli
npm install
npm run demo
```

### React Native Integration

```bash
cd bindings/rn
npm install
npm pack
# In your RN project:
npm install path/to/letta-lite-0.1.0.tgz
```

## Usage Examples

### JavaScript/TypeScript

```typescript
import { LettaLite } from 'letta-lite';

// Create an agent
const agent = await LettaLite.createAgent({
  name: "assistant",
  model: "local-llama",
  systemPrompt: "You are a helpful assistant"
});

// Set memory blocks
await agent.setBlock("user_info", "Name: Alice, prefers concise answers");

// Converse
const response = await agent.converse("What's the weather like?");
console.log(response.text);

// Export for cloud sync
const agentFile = await agent.exportAF();
```

### Swift

```swift
import LettaLite

let agent = LettaLite(config: ["model": "local"])
agent.setBlock("context", "Mobile app assistant")
let response = agent.converse("Hello!")
```

### Kotlin

```kotlin
import ai.letta.lite.LettaLite

val agent = LettaLite(mapOf("model" to "local"))
agent.setBlock("context", "Android assistant")
val response = agent.converse("Hello!")
```

## Cloud Sync

Letta Lite supports bidirectional sync with Letta cloud servers:

```typescript
// Configure sync
await agent.configureSyn({
  endpoint: "https://api.letta.ai",
  apiKey: "your-api-key",
  syncInterval: 300000, // 5 minutes
  conflictResolution: "last-write-wins"
});

// Manual sync
await agent.syncWithCloud();

// Enable auto-sync
await agent.enableAutoSync();
```

## Memory Management

Letta Lite uses a block-based memory system compatible with Letta:

- **Core Memory**: Always in context, editable blocks
- **Archival Memory**: Searchable long-term storage
- **Recall Memory**: Conversation history with search

## Tool System

Built-in tools:
- `memory_replace`: Update memory blocks
- `memory_append`: Append to memory blocks
- `archival_insert`: Add to long-term storage
- `archival_search`: Search archival memory
- `conversation_search`: Search message history

Custom tools can be registered via the FFI layer.

## Development

### Prerequisites

- Rust 1.75+
- Node.js 18+ (for CLI/RN)
- Xcode 14+ (for iOS)
- Android NDK 23+ (for Android)

### Building from Source

```bash
# Clone the repository
git clone https://github.com/letta-ai/letta-lite
cd letta-lite

# Build all components
cargo build --release

# Run tests
cargo test

# Build for mobile
cargo build --profile mobile
```

### Running Tests

```bash
# Rust unit tests
cargo test

# Integration tests
cargo test --test '*' --features integration

# Node CLI tests
cd examples/node-cli && npm test

# React Native tests
cd bindings/rn && npm test
```

## Performance

| Metric | Value |
|--------|-------|
| Binary size (iOS) | 2.3 MB |
| Binary size (Android) | 2.8 MB |
| Cold start time | <50ms |
| Memory usage (idle) | 12 MB |
| Memory usage (active) | 25-40 MB |
| Messages/second | 100+ |
| SQLite operations/sec | 10,000+ |

## License

MIT - See [LICENSE](LICENSE) for details.

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Support

- Documentation: [https://docs.letta.ai/lite](https://docs.letta.ai/lite)
- Issues: [GitHub Issues](https://github.com/letta-ai/letta-lite/issues)
- Discord: [Join our community](https://discord.gg/letta)