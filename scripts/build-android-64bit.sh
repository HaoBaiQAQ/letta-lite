#!/usr/bin/env bash
set -euo pipefail

echo "Building Letta Lite for Android (64-bit only)..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 关键：指定 Nightly 工具链（支持所有必要特性，且稳定传递 --rustflags）
TARGET_ARCH="aarch64-linux-android"
RUST_TOOLCHAIN="nightly"

# 检查必需工具
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}"
        exit 1
    fi
}

check_command rustup
check_command cargo

# 安装并切换到 Nightly 工具链（解决特性支持问题）
echo "Installing and switching to Nightly Rust toolchain..."
rustup install "$RUST_TOOLCHAIN"
rustup default "$RUST_TOOLCHAIN"

# 检查并安装cargo-ndk
if ! cargo ndk --version &> /dev/null; then
    echo -e "${YELLOW}Installing cargo-ndk...${NC}"
    cargo install cargo-ndk
fi

# 检查NDK路径环境变量
if [ -z "${NDK_HOME:-${ANDROID_NDK_HOME:-}}" ]; then
    echo -e "${RED}Error: NDK_HOME or ANDROID_NDK_HOME not set${NC}"
    echo "Please set one of these environment variables to your Android NDK path"
    exit 1
fi
NDK_HOME="${NDK_HOME:-$ANDROID_NDK_HOME}"

# 只添加64位目标架构（避免32位冲突）
echo "Adding 64-bit Android target ($TARGET_ARCH)..."
rustup target add "$TARGET_ARCH" || true

# 核心修复：用单引号包裹 --rustflags 的值，避免 shell 拆分；用 +nightly 指定工具链
echo "Building for Android ($TARGET_ARCH) with Nightly toolchain..."
NDK_SYSROOT="$NDK_HOME/sysroot/usr/lib"
LLVM_LIB_PATH="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/17/lib/linux/aarch64"
OPENSSL_PATH="/home/runner/work/letta-lite/letta-lite/openssl-install/lib"

# 正确命令：单引号包裹 --rustflags 值，确保完整传递；-- 分隔参数
cargo +"$RUST_TOOLCHAIN" ndk -t arm64-v8a -o bindings/android/src/main/jniLibs -- build -p letta-ffi --profile mobile --rustflags '-L '"$NDK_SYSROOT/aarch64-linux-android"' -L '"$LLVM_LIB_PATH"' -L '"$OPENSSL_PATH"' -llog -lunwind'

# 生成C头文件（用 Nightly 工具链）
echo "Generating C header (for $TARGET_ARCH)..."
cargo +"$RUST_TOOLCHAIN" build -p letta-ffi --target "$TARGET_ARCH" --profile mobile
cp ffi/include/letta_lite.h bindings/android/src/main/jni/ || true

# 编译64位JNI wrapper（显式链接系统库）
echo "Compiling JNI wrapper (arm64-v8a)..."
mkdir -p bindings/android/src/main/jniLibs/arm64-v8a

compile_jni() {
    local arch=$1
    local triple=$2
    local api_level=24
    echo "  Building JNI for $arch..."
    CLANG_PATH="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    "$CLANG_PATH/clang" --target="${triple}${api_level}" -I"${JAVA_HOME:-/usr/lib/jvm/default}/include" -I"${JAVA_HOME:-/usr/lib/jvm/default}/include/linux" -I"${NDK_HOME}/sysroot/usr/include" -Iffi/include -shared -o "bindings/android/src/main/jniLibs/${arch}/libletta_jni.so" bindings/android/src/main/jni/letta_jni.c -L"bindings/android/src/main/jniLibs/${arch}" -lletta_ffi -llog -lunwind
}

# 检查JNI源文件并编译
if [ -f "bindings/android/src/main/jni/letta_jni.c" ]; then
    compile_jni "arm64-v8a" "aarch64-linux-android"
else
    echo -e "${YELLOW}Warning: JNI wrapper not found, skipping JNI compilation${NC}"
fi

# 构建AAR（使用官方现成配置）
if command -v gradle &> /dev/null || [ -f "bindings/android/gradlew" ]; then
    echo "Building Android AAR (arm64-v8a)..."
    cd bindings/android
    [ -f "gradlew" ] && ./gradlew assembleRelease || gradle assembleRelease
    cd ../..
    echo -e "${GREEN}64-bit Android build complete!${NC}"
    echo "AAR location: bindings/android/build/outputs/aar/android-release.aar"
else
    echo -e "${GREEN}64-bit Android libraries built!${NC}"
    echo "Libraries location: bindings/android/src/main/jniLibs/"
fi

echo ""
echo "To use in your Android project:"
echo "1. Add the AAR file to your project's libs folder"
echo "2. Add to your app's build.gradle:"
echo "   implementation files('libs/android-release.aar')"
echo "3. Import in Kotlin: import ai.letta.lite.LettaLite"
