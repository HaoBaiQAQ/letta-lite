#!/usr/bin/env bash
set -euo pipefail

echo "Building Letta Lite for Android (64-bit only)..."

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

# Check for cargo-ndk
if ! cargo ndk --version &> /dev/null; then
    echo -e "${YELLOW}Installing cargo-ndk...${NC}"
    cargo install cargo-ndk
fi

# Check NDK_HOME or ANDROID_NDK_HOME
if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
    echo -e "${RED}Error: NDK_HOME or ANDROID_NDK_HOME not set${NC}"
    echo "Please set one of these environment variables to your Android NDK path"
    exit 1
fi

# 只添加64位目标架构（aarch64-linux-android）
echo "Adding 64-bit Android target..."
rustup target add aarch64-linux-android || true

# 只编译64位（arm64-v8a）
echo "Building for Android (arm64-v8a)..."
cargo ndk \
    -t arm64-v8a \
    -o bindings/android/src/main/jniLibs \
    build -p letta-ffi --profile mobile

# Generate header file
echo "Generating C header..."
cargo build -p letta-ffi --features cbindgen
cp ffi/include/letta_lite.h bindings/android/src/main/jni/ || true

# 只编译64位的JNI wrapper
echo "Compiling JNI wrapper (arm64-v8a)..."
NDK_HOME="${NDK_HOME:-$ANDROID_NDK_HOME}"

# 只创建64位目录
mkdir -p bindings/android/src/main/jniLibs/arm64-v8a

# 仅编译arm64-v8a的JNI
compile_jni() {
    local arch=$1
    local triple=$2
    local api_level=24
    
    echo "  Building JNI for $arch..."
    
    "${NDK_HOME}"/toolchains/llvm/prebuilt/*/bin/clang \
        --target="${triple}${api_level}" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" \
        -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" \
        -I"${NDK_HOME}/sysroot/usr/include" \
        -Iffi/include \
        -shared \
        -o "bindings/android/src/main/jniLibs/${arch}/libletta_jni.so" \
        bindings/android/src/main/jni/letta_jni.c \
        -L"bindings/android/src/main/jniLibs/${arch}" \
        -lletta_ffi
}

# Only compile JNI if the C file exists
if [ -f "bindings/android/src/main/jni/letta_jni.c" ]; then
    compile_jni "arm64-v8a" "aarch64-linux-android"
else
    echo -e "${YELLOW}Warning: JNI wrapper not found, skipping JNI compilation${NC}"
fi

# Build AAR（官方已经有现成的Gradle配置）
if command -v gradle &> /dev/null || [ -f "bindings/android/gradlew" ]; then
    echo "Building Android AAR (arm64-v8a)..."
    cd bindings/android
    if [ -f "gradlew" ]; then
        ./gradlew assembleRelease
    else
        gradle assembleRelease
    fi
    cd ../..
    
    echo -e "${GREEN}64-bit Android build complete!${NC}"
    echo ""
    echo "AAR location: bindings/android/build/outputs/aar/android-release.aar"
else
    echo -e "${GREEN}64-bit Android libraries built!${NC}"
    echo ""
    echo "Libraries location: bindings/android/src/main/jniLibs/"
fi

echo ""
echo "To use in your Android project:"
echo "1. Add the AAR file to your project's libs folder"
echo "2. Add to your app's build.gradle:"
echo "   implementation files('libs/android-release.aar')"
echo "3. Import in Kotlin: import ai.letta.lite.LettaLite"
