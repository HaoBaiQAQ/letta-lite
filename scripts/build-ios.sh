#!/usr/bin/env bash
set -euo pipefail

echo "Building Letta Lite for iOS..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check for required tools
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}"
        exit 1
    fi
}

check_command rustup
check_command cargo
check_command xcodebuild

# Add iOS targets if not already added
echo "Adding iOS targets..."
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios || true

# Build for iOS device (arm64)
echo "Building for iOS device (arm64)..."
cargo build -p letta-ffi --profile mobile --target aarch64-apple-ios

# Build for iOS simulator (arm64)
echo "Building for iOS simulator (arm64)..."
cargo build -p letta-ffi --profile mobile --target aarch64-apple-ios-sim

# Build for iOS simulator (x86_64) - for Intel Macs
echo "Building for iOS simulator (x86_64)..."
cargo build -p letta-ffi --profile mobile --target x86_64-apple-ios

# Generate header file
echo "Generating C header..."
cargo build -p letta-ffi --features cbindgen

# Create fat library for simulator
echo "Creating universal simulator library..."
mkdir -p target/ios-sim-universal
lipo -create \
    target/aarch64-apple-ios-sim/release/libletta_ffi.a \
    target/x86_64-apple-ios/release/libletta_ffi.a \
    -output target/ios-sim-universal/libletta_ffi.a

# Create XCFramework
echo "Creating XCFramework..."
rm -rf bindings/swift/LettaLite.xcframework

xcodebuild -create-xcframework \
    -library target/aarch64-apple-ios/release/libletta_ffi.a \
    -headers ffi/include \
    -library target/ios-sim-universal/libletta_ffi.a \
    -headers ffi/include \
    -output bindings/swift/LettaLite.xcframework

echo -e "${GREEN}iOS build complete!${NC}"
echo ""
echo "XCFramework location: bindings/swift/LettaLite.xcframework"
echo ""
echo "To use in your iOS project:"
echo "1. Drag LettaLite.xcframework into your Xcode project"
echo "2. Import the Swift bindings from bindings/swift/Sources/LettaLite"
echo "3. Add 'import LettaLite' in your Swift files"