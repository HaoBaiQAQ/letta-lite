#!/usr/bin/env bash
set -euo pipefail

echo "Building Letta Lite for Android (64-bit arm64-v8a only)..."

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
check_command git

# Install official cargo-ndk from GitHub (avoid Crates.io conflict)
if ! cargo ndk --version &> /dev/null; then
    echo -e "${YELLOW}Installing official cargo-ndk v4.1.2...${NC}"
    cargo install --git https://github.com/bbqsrc/cargo-ndk.git --tag v4.1.2 cargo-ndk --force
else
    if ! cargo ndk --help | grep -q "--platform"; then
        echo -e "${YELLOW}Invalid cargo-ndk found, reinstalling official version...${NC}"
        cargo uninstall cargo-ndk || true
        cargo install --git https://github.com/bbqsrc/cargo-ndk.git --tag v4.1.2 cargo-ndk --force
    fi
fi

# Print cargo-ndk help to confirm parameters (for debugging)
echo -e "\n===== cargo-ndk Parameters (v4.1.2) ====="
cargo ndk --help
echo -e "===== Parameters End ====="

# Check NDK path
if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
    echo -e "${RED}Error: NDK_HOME or ANDROID_NDK_HOME not set${NC}"
    exit 1
fi
export NDK_HOME="${NDK_HOME:-$ANDROID_NDK_HOME}"

# 仅添加64位目标架构（arm64-v8a）
echo "Adding Android 64-bit target (arm64-v8a)..."
rustup target add aarch64-linux-android || true

# 核心编译：仅编译arm64-v8a，避免多架构OpenSSL冲突
echo "Building for Android 64-bit (arm64-v8a)..."
cargo ndk \
    -t arm64-v8a \
    --platform 21 \
    -o bindings/android/src/main/jniLibs \
    -- build -p letta-ffi --profile mobile

# Generate and copy C header file（核心修复：去掉 --features cbindgen）
echo "Generating C header..."
cargo build -p letta-ffi # 去掉无效的 feature 参数
if [ -f "ffi/include/letta_lite.h" ]; then
    cp ffi/include/letta_lite.h bindings/android/src/main/jni/
else
    echo -e "${RED}Error: letta_lite.h not found in ffi/include/${NC}"
    exit 1
fi

# 仅编译64位JNI wrapper（arm64-v8a）
echo "Compiling JNI wrapper (arm64-v8a)..."
mkdir -p bindings/android/src/main/jniLibs/arm64-v8a

compile_jni() {
    local arch=$1
    local triple=$2
    local api_level=21
    echo "  Building JNI for $arch (API $api_level)..."

    # 自动查找arm64-v8a对应的Clang路径
    CLANG_PATH=$(find "$NDK_HOME/toolchains/llvm/prebuilt/" -name "${triple}${api_level}-clang" | head -1)
    if [ -z "$CLANG_PATH" ]; then
        echo -e "${RED}Error: Clang not found for ${triple}${api_level}${NC}"
        exit 1
    fi

    # Java include路径兼容
    local JAVA_INCLUDE="${JAVA_HOME:-/usr/lib/jvm/default-java}/include"
    [ ! -d "$JAVA_INCLUDE" ] && JAVA_INCLUDE="/usr/lib/jvm/java-11-openjdk-amd64/include"

    "$CLANG_PATH" \
        -I"$JAVA_INCLUDE" \
        -I"$JAVA_INCLUDE/linux" \
        -I"$NDK_HOME/sysroot/usr/include" \
        -I"ffi/include" \
        -shared -fPIC \
        -o "bindings/android/src/main/jniLibs/${arch}/libletta_jni.so" \
        bindings/android/src/main/jni/letta_jni.c \
        -L"bindings/android/src/main/jniLibs/${arch}" \
        -lletta_ffi \
        -llog \
        -ldl
}

# 仅编译arm64-v8a的JNI
if [ -f "bindings/android/src/main/jni/letta_jni.c" ]; then
    compile_jni "arm64-v8a" "aarch64-linux-android"
else
    echo -e "${RED}Error: JNI source file (letta_jni.c) not found${NC}"
    exit 1
fi

# Build Android AAR（仅64位）
echo "Building Android AAR (arm64-v8a)..."
cd bindings/android
if [ -f "gradlew" ]; then
    chmod +x gradlew
    ./gradlew clean assembleRelease --no-daemon
else
    echo -e "${RED}Error: gradlew not found in bindings/android${NC}"
    exit 1
fi
cd ../..

# 验证构建结果
AAR_PATH="bindings/android/build/outputs/aar/android-release.aar"
if [ -f "$AAR_PATH" ]; then
    echo -e "\n${GREEN}✅ Android 64-bit (arm64-v8a) build successful!${NC}"
    echo -e "📁 AAR Location: $AAR_PATH"
else
    echo -e "\n${RED}❌ Error: AAR file not generated${NC}"
    exit 1
fi

# Usage guide
echo -e "\n📋 Usage Instructions:"
echo "1. Copy the AAR file to your Android project's 'app/libs' folder"
echo "2. Add to app/build.gradle:"
echo "   dependencies {"
echo "       implementation files('libs/android-release.aar')"
echo "   }"
echo "3. Ensure minSdkVersion ≥ 21"
echo "4. Import in Kotlin: import ai.letta.lite.LettaLite"
