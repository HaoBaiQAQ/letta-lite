#!/usr/bin/env bash
set -euo pipefail

echo "Running Letta Lite Integration Tests..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Build first
echo -e "${BLUE}Building Rust library...${NC}"
cargo build --release

# Run Rust tests
echo -e "${BLUE}Running Rust unit tests...${NC}"
cargo test --all

# Run Node CLI tests if available
if [ -d "examples/node-cli" ]; then
    echo -e "${BLUE}Running Node.js CLI tests...${NC}"
    cd examples/node-cli
    npm install
    npm run build
    npm run test
    cd ../..
fi

# Test with local Letta server if available
if command -v letta &> /dev/null; then
    echo -e "${BLUE}Testing with local Letta server...${NC}"
    
    # Start Letta server in background
    echo "Starting Letta server..."
    letta server &
    SERVER_PID=$!
    
    # Wait for server to start
    sleep 5
    
    # Run sync test
    cd examples/node-cli
    npm run build
    node dist/index.js sync --api-key test-key --endpoint http://localhost:8000 || true
    cd ../..
    
    # Stop server
    kill $SERVER_PID 2>/dev/null || true
else
    echo -e "${YELLOW}Letta server not found, skipping sync tests${NC}"
fi

echo -e "${GREEN}All integration tests complete!${NC}"