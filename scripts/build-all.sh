#!/usr/bin/env bash
set -euo pipefail

echo "Building Letta Lite for all platforms..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Build Rust core first
echo -e "${BLUE}Building Rust core...${NC}"
cargo build --release

# Run tests
echo -e "${BLUE}Running tests...${NC}"
cargo test

# Build for iOS
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo -e "${BLUE}Building for iOS...${NC}"
    ./scripts/build-ios.sh
else
    echo -e "${YELLOW}Skipping iOS build (requires macOS)${NC}"
fi

# Build for Android
echo -e "${BLUE}Building for Android...${NC}"
./scripts/build-android.sh

# Build Node.js CLI
echo -e "${BLUE}Building Node.js CLI...${NC}"
cd examples/node-cli
npm install
npm run build
cd ../..

echo -e "${GREEN}All builds complete!${NC}"