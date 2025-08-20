# Contributing to Letta Lite

We welcome contributions to Letta Lite! This document provides guidelines for contributing to the project.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/yourusername/letta-lite.git`
3. Create a feature branch: `git checkout -b feature/your-feature`
4. Make your changes
5. Run tests: `cargo test`
6. Commit your changes: `git commit -am 'Add new feature'`
7. Push to your fork: `git push origin feature/your-feature`
8. Create a Pull Request

## Development Setup

### Prerequisites

- Rust 1.75+ (install via [rustup](https://rustup.rs/))
- Node.js 18+ (for CLI and React Native)
- Xcode 14+ (for iOS development, macOS only)
- Android NDK 23+ (for Android development)

### Building from Source

```bash
# Clone the repository
git clone https://github.com/letta-ai/letta-lite
cd letta-lite

# Build the Rust core
cargo build --release

# Run tests
cargo test

# Build for mobile platforms
./scripts/build-all.sh
```

## Code Style

### Rust

- Follow the [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/)
- Use `cargo fmt` before committing
- Use `cargo clippy` to catch common mistakes
- Write documentation for public APIs
- Add tests for new functionality

### TypeScript/JavaScript

- Use TypeScript for all new code
- Follow the existing code style
- Use ESLint: `npm run lint`
- Write JSDoc comments for public APIs

### Swift

- Follow [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- Use SwiftLint if available
- Document public APIs with comments

### Kotlin

- Follow [Kotlin Coding Conventions](https://kotlinlang.org/docs/coding-conventions.html)
- Use ktlint for formatting
- Document public APIs with KDoc

## Testing

### Unit Tests

```bash
# Run Rust tests
cargo test

# Run specific test
cargo test test_agent_lifecycle

# Run with verbose output
cargo test -- --nocapture
```

### Integration Tests

```bash
# Run integration tests
./scripts/test-integration.sh

# Test with local Letta server
letta server &
cargo test --features sync
```

### Mobile Testing

```bash
# iOS (requires macOS)
cd bindings/swift
swift test

# Android
cd bindings/android
./gradlew test
```

## Documentation

- Update README.md for user-facing changes
- Update inline documentation for API changes
- Add examples for new features
- Update CHANGELOG.md following [Keep a Changelog](https://keepachangelog.com/)

## Pull Request Process

1. **Before submitting:**
   - Ensure all tests pass
   - Update documentation
   - Add tests for new features
   - Run formatters and linters

2. **PR Description:**
   - Describe what changes you've made
   - Link to any relevant issues
   - Include screenshots for UI changes
   - List any breaking changes

3. **Review Process:**
   - PRs require at least one review
   - Address review feedback
   - Keep PRs focused and small when possible

## Architecture Decisions

### Core Principles

1. **Minimal Binary Size**: Optimize for mobile deployment
2. **Offline-First**: All core functionality works without internet
3. **Cross-Platform**: Support iOS, Android, and desktop equally
4. **AF Compatibility**: Maintain compatibility with Letta Agent Files

### Adding New Features

When adding new features, consider:

1. **Memory Impact**: Mobile devices have limited memory
2. **Battery Usage**: Minimize CPU usage for mobile
3. **Storage**: Use efficient storage formats
4. **Sync**: How will this sync with cloud?

### Provider Integration

To add a new LLM provider:

1. Create a new provider module in `providers/`
2. Implement the `LlmProvider` trait
3. Add to `ProviderFactory::create()`
4. Add configuration types
5. Write tests

Example:

```rust
pub struct MyProvider {
    // ...
}

#[async_trait]
impl LlmProvider for MyProvider {
    async fn complete(&self, request: CompletionRequest) -> Result<Completion> {
        // Implementation
    }
    
    fn name(&self) -> &str {
        "my-provider"
    }
}
```

## Debugging

### Rust Debugging

```bash
# Enable debug logs
RUST_LOG=debug cargo run

# Use lldb/gdb
rust-lldb target/debug/letta-ffi
```

### Mobile Debugging

```bash
# iOS Console logs
xcrun simctl spawn booted log stream --level debug

# Android logcat
adb logcat | grep -i letta
```

## Performance

### Profiling

```bash
# CPU profiling with cargo-flamegraph
cargo install flamegraph
cargo flamegraph --bin letta-ffi

# Memory profiling with Valgrind
valgrind --tool=massif target/release/letta-ffi
```

### Benchmarks

```bash
# Run benchmarks
cargo bench

# Compare benchmarks
cargo bench -- --save-baseline before
# Make changes
cargo bench -- --baseline before
```

## Security

- Never commit API keys or secrets
- Use environment variables for sensitive data
- Validate all user input
- Use safe Rust practices (avoid `unsafe` when possible)
- Report security issues privately to security@letta.ai

## Release Process

1. Update version in `Cargo.toml` files
2. Update CHANGELOG.md
3. Create git tag: `git tag v0.1.0`
4. Push tag: `git push origin v0.1.0`
5. CI will build and create release

## Community

- Join our [Discord](https://discord.gg/letta)
- Follow [@LettaAI](https://twitter.com/lettaai) on Twitter
- Read our [blog](https://blog.letta.ai)

## License

By contributing to Letta Lite, you agree that your contributions will be licensed under the MIT License.